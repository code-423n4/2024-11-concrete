//SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.24;

import {ERC4626Upgradeable, IERC20, IERC20Metadata} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultFees, Strategy, IConcreteMultiStrategyVault, Allocation} from "../interfaces/IConcreteMultiStrategyVault.sol";
import {Errors} from "../interfaces/Errors.sol";
import {IStrategy, ReturnedRewards} from "../interfaces/IStrategy.sol";
import {IWithdrawalQueue} from "../interfaces/IWithdrawalQueue.sol";
import {MultiStrategyVaultHelper} from "../libraries/MultiStrategyVaultHelper.sol";
import {MAX_BASIS_POINTS} from "../utils/Constants.sol";
/**
 *
 * @title ConcreteMultiStrategyVault
 * @author TooFar
 * @notice See the following for full EIP-4626 specification https://eips.ethereum.org/EIPS/eip-4626.
 *
 * An ERC4626 compliant vault that manages multiple yield generating strategies.
 * Fully delegates interaction with third parties to the strategies contained herein
 * Allows the protocol to collect multiple types of fees. Fees are configurable
 */

contract ConcreteMultiStrategyVault is
    ERC4626Upgradeable,
    Errors,
    ReentrancyGuard,
    PausableUpgradeable,
    OwnableUpgradeable,
    IConcreteMultiStrategyVault
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint32 private constant DUST = 1e8;
    uint256 private constant PRECISION = 1e36;
    uint256 public firstDeposit = 0;
    /// @dev Public variable storing the address of the protectStrategy contract.
    address public protectStrategy;
    /// @dev Represents the number of seconds in a year, accounting for leap years.
    uint256 private constant SECONDS_PER_YEAR = 365.25 days;
    /// @dev Internal variable to store the number of decimals the vault's shares will have.
    uint8 private _decimals;
    /// @notice The offset applied to decimals to prevent inflation attacks.
    /// @dev Public constant representing the offset applied to the vault's share decimals.
    uint8 public constant decimalOffset = 9;
    /// @notice The highest value of share price recorded, used for performance fee calculation.
    /// @dev Public variable to store the high water mark for performance fee calculation.
    uint256 public highWaterMark;
    /// @notice The maximum amount of assets that can be deposited into the vault.
    /// @dev Public variable to store the deposit limit of the vault.
    uint256 public depositLimit;
    /// @notice The timestamp at which the fees were last updated.
    /// @dev Public variable to store the last update time of the fees.
    uint256 public feesUpdatedAt;
    /// @notice The recipient address for any fees collected by the vault.
    /// @dev Public variable to store the address of the fee recipient.
    address public feeRecipient;
    /// @notice Indicates if the vault is in idle mode, where deposits are not passed to strategies.
    /// @dev Public boolean indicating if the vault is idle.
    bool public vaultIdle;

    /// @notice The array of strategies that the vault can interact with.
    /// @dev Public array storing the strategies associated with the vault.
    Strategy[] internal strategies;
    /// @notice The fee structure of the vault.
    /// @dev Public variable storing the fees associated with the vault.
    VaultFees private fees;

    IWithdrawalQueue public withdrawalQueue;

    //Rewards Management
    // Array to store reward addresses
    address[] private rewardAddresses;

    // Mapping to get the index of each reward address
    mapping(address => uint256) public rewardIndex;

    // Mapping to store the reward index for each user and reward address
    mapping(address => mapping(address => uint256)) public userRewardIndex;

    // Mapping to store the total rewards claimed by user for each reward address
    mapping(address => mapping(address => uint256)) public totalRewardsClaimed;

    event Initialized(address indexed vaultName, address indexed underlyingAsset);

    event RequestedFunds(address indexed protectStrategy, uint256 amount);

    event RewardsHarvested();
    /// @notice Modifier to restrict access to only the designated protection strategy account.
    /// @dev Reverts the transaction if the sender is not the protection strategy account.

    modifier onlyProtect() {
        if (protectStrategy != _msgSender()) {
            revert ProtectUnauthorizedAccount(_msgSender());
        }
        _;
    }

    ///@notice Modifier that allows protocol to take fees
    modifier takeFees() {
        uint256 totalFee = accruedProtocolFee() + accruedPerformanceFee();
        uint256 shareValue = convertToAssets(1e18);
        uint256 _totalAssets = totalAssets();

        if (shareValue > highWaterMark) highWaterMark = shareValue;

        if (totalFee > 0 && _totalAssets > 0) {
            uint256 supply = totalSupply();
            uint256 feeInShare = supply == 0
                ? totalFee
                : totalFee.mulDiv(supply, _totalAssets - totalFee, Math.Rounding.Floor);
            _mint(feeRecipient, feeInShare);
        }
        feesUpdatedAt = block.timestamp;
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the vault with the given parameters.
     * @dev Sets up the vault with base asset, share name and symbol, strategies, fee recipient, fees, deposit limit, and owner.
     *      Approves the maximum amount of the base asset for each strategy.
     * @param baseAsset_ The base asset of the vault.
     * @param shareName_ The name of the vault's shares.
     * @param shareSymbol_ The symbol of the vault's shares.
     * @param strategies_ The array of strategies that the vault will use.
     * @param feeRecipient_ The recipient of the fees collected by the vault.
     * @param fees_ The fee structure for the vault.
     * @param depositLimit_ The maximum amount that can be deposited into the vault.
     * @param owner_ The owner of the vault.
     */
    // slither didn't detect the nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,calls-loop,costly-loop
    function initialize(
        IERC20 baseAsset_,
        string memory shareName_,
        string memory shareSymbol_,
        Strategy[] memory strategies_,
        address feeRecipient_,
        VaultFees memory fees_,
        uint256 depositLimit_,
        address owner_
    ) external initializer nonReentrant {
        __Pausable_init();
        __ERC4626_init(baseAsset_);
        __ERC20_init(shareName_, shareSymbol_);
        __Ownable_init(owner_);

        if (address(baseAsset_) == address(0)) revert InvalidAssetAddress();

        (protectStrategy, _decimals) = MultiStrategyVaultHelper.validateVaultParameters(
            baseAsset_,
            decimalOffset,
            strategies_,
            protectStrategy,
            strategies,
            fees_,
            fees
        );
        if (feeRecipient_ == address(0)) {
            revert InvalidFeeRecipient();
        }
        feeRecipient = feeRecipient_;

        highWaterMark = 1e9; // Set the initial high water mark for performance fee calculation.
        depositLimit = depositLimit_;

        // By default, the vault is not idle. It can be set to idle mode using toggleVaultIdle(true).
        vaultIdle = false;

        emit Initialized(address(this), address(baseAsset_));
    }

    /**
     * @notice Returns the decimals of the vault's shares.
     * @dev Overrides the decimals function in inherited contracts to return the custom vault decimals.
     * @return The decimals of the vault's shares.
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Pauses all deposit and withdrawal functions.
     * @dev Can only be called by the owner. Emits a `Paused` event.
     */
    function pause() public onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the vault, allowing deposit and withdrawal functions.
     * @dev Can only be called by the owner. Emits an `Unpaused` event.
     */
    function unpause() public onlyOwner {
        _unpause();
    }

    // ========== PUBLIC ENTRY DEPOSIT/WITHDRAW =============
    /**
     * @notice Allows a user to deposit assets into the vault in exchange for shares.
     * @dev This function is a wrapper that calls the main deposit function with the sender's address as the receiver.
     * @param assets_ The amount of assets to deposit.
     * @return The number of shares minted for the deposited assets.
     */
    function deposit(uint256 assets_) external returns (uint256) {
        return deposit(assets_, msg.sender);
    }

    /**
     * @notice Deposits assets into the vault on behalf of a receiver, in exchange for shares.
     * @dev Calculates the deposit fee, mints shares to the fee recipient and the receiver, then transfers the assets from the sender.
     *      If the vault is not idle, it also allocates the assets into the strategies according to their allocation.
     * @param assets_ The amount of assets to deposit.
     * @param receiver_ The address for which the shares will be minted.
     * @return shares The number of shares minted for the deposited assets.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function deposit(
        uint256 assets_,
        address receiver_
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        _validateAndUpdateDepositTimestamps(receiver_);

        if (assets_ > maxDeposit(receiver_) || assets_ > depositLimit) revert MaxError();

        // Calculate the fee in shares
        uint256 feeShares = _convertToShares(
            assets_.mulDiv(uint256(fees.depositFee), MAX_BASIS_POINTS, Math.Rounding.Floor),
            Math.Rounding.Floor
        );

        // Calculate the net shares to mint for the deposited assets
        shares = _convertToShares(assets_, Math.Rounding.Floor) - feeShares;
        if (shares <= DUST) revert ZeroAmount();

        // Mint shares to fee recipient and receiver
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        _mint(receiver_, shares);

        // Transfer the assets from the sender to the vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets_);

        // If the vault is not idle, allocate the assets into strategies
        if (!vaultIdle) {
            uint256 len = strategies.length;
            for (uint256 i; i < len; ) {
                //We control both the length of the array and the external call
                //slither-disable-next-line unused-return,calls-loop
                strategies[i].strategy.deposit(
                    assets_.mulDiv(strategies[i].allocation.amount, MAX_BASIS_POINTS, Math.Rounding.Floor),
                    address(this)
                );
                unchecked {
                    i++;
                }
            }
        }
        emit Deposit(msg.sender, receiver_, assets_, shares);
    }

    /**
     * @notice Allows a user to mint shares in exchange for assets.
     * @dev This function is a wrapper that calls the main mint function with the sender's address as the receiver.
     * @param shares_ The number of shares to mint.
     * @return The amount of assets deposited in exchange for the minted shares.
     */
    function mint(uint256 shares_) external returns (uint256) {
        return mint(shares_, msg.sender);
    }

    /**
     * @notice Mints shares on behalf of a receiver, in exchange for assets.
     * @dev Calculates the deposit fee in shares, mints shares to the fee recipient and the receiver, then transfers the assets from the sender.
     *      If the vault is not idle, it also allocates the assets into the strategies according to their allocation.
     * @param shares_ The number of shares to mint.
     * @param receiver_ The address for which the shares will be minted.
     * @return assets The amount of assets deposited in exchange for the minted shares.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function mint(
        uint256 shares_,
        address receiver_
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        _validateAndUpdateDepositTimestamps(receiver_);

        if (shares_ == 0) revert ZeroAmount();

        // Calculate the deposit fee in shares
        uint256 depositFee = uint256(fees.depositFee);
        uint256 feeShares = shares_.mulDiv(MAX_BASIS_POINTS, MAX_BASIS_POINTS - depositFee, Math.Rounding.Floor) -
            shares_;

        // Calculate the total assets required for the minted shares, including fees
        assets = _convertToAssets(shares_ + feeShares, Math.Rounding.Ceil);

        if (assets > maxMint(receiver_)) revert MaxError();

        // Mint shares to fee recipient and receiver
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        _mint(receiver_, shares_);

        // Transfer the assets from the sender to the vault
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // If the vault is not idle, allocate the assets into strategies
        if (!vaultIdle) {
            uint256 len = strategies.length;
            for (uint256 i; i < len; ) {
                //We control both the length of the array and the external call
                // slither-disable-next-line unused-return,calls-loop
                strategies[i].strategy.deposit(
                    assets.mulDiv(strategies[i].allocation.amount, MAX_BASIS_POINTS, Math.Rounding.Ceil),
                    address(this)
                );
                unchecked {
                    i++;
                }
            }
        }
    }

    /**
     * @notice Redeems shares for the caller and sends the assets to the caller.
     * @dev This is a convenience function that calls the main redeem function with the caller as both receiver and owner.
     * @param shares_ The number of shares to redeem.
     * @return assets The amount of assets returned in exchange for the redeemed shares.
     */
    function redeem(uint256 shares_) external returns (uint256) {
        return redeem(shares_, msg.sender, msg.sender);
    }

    /**
     * @notice Redeems shares on behalf of an owner and sends the assets to a receiver.
     * @dev Redeems the specified amount of shares from the owner's balance, deducts the withdrawal fee in shares, burns the shares, and sends the assets to the receiver.
     *      If the caller is not the owner, it requires approval.
     * @param shares_ The number of shares to redeem.
     * @param receiver_ The address to receive the assets.
     * @param owner_ The owner of the shares being redeemed.
     * @return assets The amount of assets returned in exchange for the redeemed shares.
     */
    function redeem(
        uint256 shares_,
        address receiver_,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 assets) {
        if (receiver_ == address(0)) revert InvalidRecipient();
        if (shares_ == 0) revert ZeroAmount();
        if (shares_ > maxRedeem(owner_)) revert MaxError();

        uint256 feeShares = shares_.mulDiv(uint256(fees.withdrawalFee), MAX_BASIS_POINTS, Math.Rounding.Ceil);

        assets = _convertToAssets(shares_ - feeShares, Math.Rounding.Floor);

        _withdraw(assets, receiver_, owner_, shares_, feeShares);
    }

    /**
     * @notice Withdraws a specified amount of assets for the caller.
     * @dev This is a convenience function that calls the main withdraw function with the caller as both receiver and owner.
     * @param assets_ The amount of assets to withdraw.
     * @return shares The number of shares burned in exchange for the withdrawn assets.
     */
    function withdraw(uint256 assets_) external returns (uint256) {
        return withdraw(assets_, msg.sender, msg.sender);
    }

    /**
     * @notice Withdraws a specified amount of assets on behalf of an owner and sends them to a receiver.
     * @dev Calculates the number of shares equivalent to the assets requested, deducts the withdrawal fee in shares, burns the shares, and sends the assets to the receiver.
     *      If the caller is not the owner, it requires approval.
     * @param assets_ The amount of assets to withdraw.
     * @param receiver_ The address to receive the withdrawn assets.
     * @param owner_ The owner of the shares equivalent to the assets being withdrawn.
     * @return shares The number of shares burned in exchange for the withdrawn assets.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function withdraw(
        uint256 assets_,
        address receiver_,
        address owner_
    ) public override nonReentrant whenNotPaused returns (uint256 shares) {
        if (receiver_ == address(0)) revert InvalidRecipient();
        if (assets_ > maxWithdraw(owner_)) revert MaxError();
        shares = _convertToShares(assets_, Math.Rounding.Ceil);
        if (shares <= DUST) revert ZeroAmount();

        // If msg.sender is the withdrawal queue, go straght to the actual withdrawal
        uint256 withdrawalFee = uint256(fees.withdrawalFee);
        uint256 feeShares = msg.sender != feeRecipient
            ? shares.mulDiv(MAX_BASIS_POINTS, MAX_BASIS_POINTS - withdrawalFee, Math.Rounding.Floor) - shares
            : 0;
        shares += feeShares;

        _withdraw(assets_, receiver_, owner_, shares, feeShares);
    }

    /**
     * @notice Consumes allowance, burn shares, mint fees and transfer assets to receiver
     * @dev internal function for redeem and withdraw
     * @param assets_ The amount of assets to withdraw.
     * @param receiver_ The address to receive the withdrawn assets.
     * @param owner_ The owner of the shares equivalent to the assets being withdrawn.
     * @param shares The address to receive the withdrawn assets.
     * @param feeShares The owner of the shares equivalent to the assets being withdrawn.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function _withdraw(uint256 assets_, address receiver_, address owner_, uint256 shares, uint256 feeShares) private {
        if (msg.sender != owner_) {
            _approve(owner_, msg.sender, allowance(owner_, msg.sender) - shares);
        }
        _burn(owner_, shares);
        if (feeShares > 0) _mint(feeRecipient, feeShares);
        uint256 availableAssetsForWithdrawal = getAvailableAssetsForWithdrawal();
        if (availableAssetsForWithdrawal >= assets_) {
            _withdrawStrategyFunds(assets_, receiver_);
        } else {
            if (address(withdrawalQueue) == address(0)) {
                revert InsufficientVaultFunds(address(this), assets_, availableAssetsForWithdrawal);
            }
            withdrawalQueue.requestWithdrawal(receiver_, assets_);
        }
        emit Withdraw(msg.sender, receiver_, owner_, assets_, shares);
    }

    /**
     * @dev Internal function to withdraw funds from strategies to fulfill withdrawal requests.
     * @param amount_ The amount of assets to withdraw.
     * @param receiver_ The address to receive the withdrawn assets.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function _withdrawStrategyFunds(uint256 amount_, address receiver_) private {
        IERC20 asset_ = IERC20(asset());
        //Not in a loop
        //slither-disable-next-line calls-loop
        uint256 float = asset_.balanceOf(address(this));
        // If there is enough in the vault, send the full amount
        if (amount_ <= float) {
            asset_.safeTransfer(receiver_, amount_);
        } else {
            uint256 diff = amount_ - float;
            uint256 totalWithdrawn = 0;
            uint256 len = strategies.length;
            for (uint256 i; i < len; ) {
                Strategy memory strategy = strategies[i];
                //We control both the length of the array and the external call
                //slither-disable-next-line calls-loop
                uint256 withdrawable = strategy.strategy.previewRedeem(strategy.strategy.balanceOf(address(this)));
                if (diff.mulDiv(strategy.allocation.amount, MAX_BASIS_POINTS, Math.Rounding.Ceil) > withdrawable) {
                    revert InsufficientFunds(strategy.strategy, diff * strategy.allocation.amount, withdrawable);
                }
                uint256 amountToWithdraw = amount_.mulDiv(
                    strategy.allocation.amount,
                    MAX_BASIS_POINTS,
                    Math.Rounding.Ceil
                );
                //We control both the length of the array and the external call
                //slither-disable-next-line unused-return,calls-loop
                strategy.strategy.withdraw(amountToWithdraw, receiver_, address(this));
                totalWithdrawn += amountToWithdraw;
                unchecked {
                    i++;
                }
            }
            // If enough wasn't drawn out, use the float (this is due to dust)
            if (totalWithdrawn < amount_ && amount_ - totalWithdrawn <= float) {
                asset_.safeTransfer(receiver_, amount_ - totalWithdrawn);
            }
        }
    }

    /**
     * @notice Prepares and executes the withdrawal process for a specific withdrawal request.
     * @dev Calls the prepareWithdrawal function to obtain withdrawal details such as recipient address, withdrawal amount, and updated available assets.
     * @dev Compares the original available assets with the updated available assets to determine if funds need to be withdrawn from the strategy.
     * @dev If the available assets have changed, calls the _withdrawStrategyFunds function to withdraw funds from the strategy and transfer them to the recipient.
     * @param _requestId The identifier of the withdrawal request.
     * @param avaliableAssets The amount of available assets for withdrawal.
     * @return The new available assets after processing the withdrawal.
     */
    //we control the external call
    //slither-disable-next-line calls-loop,naming-convention
    function claimWithdrawal(uint256 _requestId, uint256 avaliableAssets) private returns (uint256) {
        (address recipient, uint256 amount, uint256 newAvaliableAssets) = withdrawalQueue.prepareWithdrawal(
            _requestId,
            avaliableAssets
        );

        if (avaliableAssets != newAvaliableAssets) {
            _withdrawStrategyFunds(amount, recipient);
        }
        return newAvaliableAssets;
    }

    function getRewardTokens() public view returns (address[] memory) {
        return rewardAddresses;
    }

    function getAvailableAssetsForWithdrawal() public view returns (uint256 totalAvailable) {
        totalAvailable = IERC20(asset()).balanceOf(address(this));
        uint256 len = strategies.length;
        for (uint256 i; i < len; ) {
            Strategy memory strategy = strategies[i];
            //We control both the length of the array and the external call
            //slither-disable-next-line calls-loop
            totalAvailable += strategy.strategy.getAvailableAssetsForWithdrawal();
            unchecked {
                i++;
            }
        }
        return totalAvailable;
    }

    /**
     * @notice Updates the user rewards to the current reward index.
     * @dev Calculates the rewards to be transferred to the user based on the difference between the current and previous reward indexes.
     * @param userAddress The address of the user to update rewards for.
     */
    //slither-disable-next-line unused-return,calls-loop,reentrancy-no-eth
    function getUserRewards(address userAddress) external view returns (ReturnedRewards[] memory) {
        uint256 userBalance = balanceOf(userAddress);
        uint256 len = rewardAddresses.length;
        ReturnedRewards[] memory returnedRewards = new ReturnedRewards[](len);
        for (uint256 i; i < len; ) {
            uint256 tokenRewardIndex = rewardIndex[rewardAddresses[i]];
            uint256 calculatedRewards = (tokenRewardIndex - userRewardIndex[userAddress][rewardAddresses[i]]).mulDiv(
                userBalance,
                PRECISION,
                Math.Rounding.Floor
            );
            returnedRewards[i] = ReturnedRewards(rewardAddresses[i], calculatedRewards);
            unchecked {
                i++;
            }
        }
        return returnedRewards;
    }

    // function to returns all the rewards claimed by a user for all the reward tokens in the vault
    function getTotalRewardsClaimed(address userAddress) external view returns (ReturnedRewards[] memory) {
        uint256 len = rewardAddresses.length;
        ReturnedRewards[] memory claimedRewards = new ReturnedRewards[](len);
        for (uint256 i; i < len; ) {
            claimedRewards[i] = ReturnedRewards(
                rewardAddresses[i],
                totalRewardsClaimed[userAddress][rewardAddresses[i]]
            );
            unchecked {
                i++;
            }
        }
        return claimedRewards;
    }
    // ================= ACCOUNTING =====================
    /**
     * @notice Calculates the total assets under management in the vault, including those allocated to strategies.
     * @dev Sums the balance of the vault's asset held directly and the assets managed by each strategy.
     * @return total The total assets under management in the vault.
     */

    function totalAssets() public view override returns (uint256 total) {
        total = IERC20(asset()).balanceOf(address(this));
        for (uint256 i; i < strategies.length; ) {
            //We control both the length of the array and the external call
            //slither-disable-next-line calls-loop
            total += strategies[i].strategy.convertToAssets(strategies[i].strategy.balanceOf(address(this)));
            unchecked {
                i++;
            }
        }
        uint256 unfinalized = 0;
        if (address(withdrawalQueue) != address(0)) {
            unfinalized = withdrawalQueue.unfinalizedAmount();
        }

        //not a timestamp
        //slither-disable-next-line timestamp
        if (total < unfinalized) revert InvalidSubstraction();
        total -= unfinalized;
    }

    /**
     * @notice Provides a preview of the number of shares that would be minted for a given deposit amount, after fees.
     * @dev Calculates the deposit fee and subtracts it from the deposit amount to determine the net amount for share conversion.
     * @param assets_ The amount of assets to be deposited.
     * @return The number of shares that would be minted for the given deposit amount.
     */
    function previewDeposit(uint256 assets_) public view override returns (uint256) {
        uint256 netAssets = assets_ -
            (
                msg.sender != feeRecipient
                    ? assets_.mulDiv(uint256(fees.depositFee), MAX_BASIS_POINTS, Math.Rounding.Floor)
                    : 0
            );
        return _convertToShares(netAssets, Math.Rounding.Floor);
    }

    /**
     * @notice Provides a preview of the amount of assets required to mint a specific number of shares, after accounting for deposit fees.
     * @dev Adds the deposit fee to the share amount to determine the gross amount for asset conversion.
     * @param shares_ The number of shares to be minted.
     * @return The amount of assets required to mint the specified number of shares.
     */
    function previewMint(uint256 shares_) public view override returns (uint256) {
        uint256 grossShares = shares_.mulDiv(MAX_BASIS_POINTS, MAX_BASIS_POINTS - fees.depositFee, Math.Rounding.Floor);
        return _convertToAssets(grossShares, Math.Rounding.Floor);
    }

    /**
     * @notice Provides a preview of the number of shares that would be burned for a given withdrawal amount, after fees.
     * @dev Calculates the withdrawal fee and adds it to the share amount to determine the gross shares for asset conversion.
     * @param assets_ The amount of assets to be withdrawn.
     * @return shares The number of shares that would be burned for the given withdrawal amount.
     */
    function previewWithdraw(uint256 assets_) public view override returns (uint256 shares) {
        shares = _convertToShares(assets_, Math.Rounding.Ceil);
        shares = msg.sender != feeRecipient
            ? shares.mulDiv(MAX_BASIS_POINTS, MAX_BASIS_POINTS - fees.withdrawalFee, Math.Rounding.Floor)
            : shares;
    }

    /**
     * @notice Provides a preview of the amount of assets that would be redeemed for a specific number of shares, after withdrawal fees.
     * @dev Subtracts the withdrawal fee from the share amount to determine the net shares for asset conversion.
     * @param shares_ The number of shares to be redeemed.
     * @return The amount of assets that would be redeemed for the specified number of shares.
     */
    function previewRedeem(uint256 shares_) public view override returns (uint256) {
        uint256 netShares = shares_ -
            (
                msg.sender != feeRecipient
                    ? shares_.mulDiv(uint256(fees.withdrawalFee), MAX_BASIS_POINTS, Math.Rounding.Floor)
                    : 0
            );
        return _convertToAssets(netShares, Math.Rounding.Floor);
    }

    /**
     * @notice Calculates the maximum amount of assets that can be minted, considering the deposit limit and current total assets.
     * @dev Returns zero if the vault is paused or if the total assets are equal to or exceed the deposit limit.
     * @return The maximum amount of assets that can be minted.
     */
    //We're not using the timestamp for comparisions
    //slither-disable-next-line timestamp
    function maxMint(address) public view override returns (uint256) {
        return (paused() || totalAssets() >= depositLimit) ? 0 : depositLimit - totalAssets();
    }

    /**
     * @notice Converts an amount of assets to the equivalent amount of shares, considering the current share price and applying the specified rounding.
     * @dev Utilizes the total supply and total assets to calculate the share price for conversion.
     * @param assets The amount of assets to convert to shares.
     * @param rounding The rounding direction to use for the conversion.
     * @return shares The equivalent amount of shares for the given assets.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256 shares) {
        shares = assets.mulDiv(totalSupply() + 10 ** decimalOffset, totalAssets() + 1, rounding);
    }

    /**
     * @notice Converts an amount of shares to the equivalent amount of assets, considering the current share price and applying the specified rounding.
     * @dev Utilizes the total assets and total supply to calculate the asset price for conversion.
     * @param shares The amount of shares to convert to assets.
     * @param rounding The rounding direction to use for the conversion.
     * @return The equivalent amount of assets for the given shares.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view virtual override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + 10 ** decimalOffset, rounding);
    }

    // ============ FEE ACCOUNTING =====================
    /**
     * @notice Calculates the accrued protocol fee based on the current protocol fee rate and time elapsed.
     * @dev The protocol fee is calculated as a percentage of the total assets, prorated over time since the last fee update.
     * @return The accrued protocol fee in asset units.
     */
    function accruedProtocolFee() public view returns (uint256) {
        // Only calculate if a protocol fee is set
        if (fees.protocolFee > 0) {
            // Calculate the fee based on time elapsed and total assets, using floor rounding for precision
            return
                uint256(fees.protocolFee).mulDiv(
                    totalAssets() * (block.timestamp - feesUpdatedAt),
                    SECONDS_PER_YEAR,
                    Math.Rounding.Floor
                ) / 10000; // Normalize the fee percentage
        } else {
            return 0;
        }
    }

    /**
     * @notice Calculates the accrued performance fee based on the vault's performance relative to the high water mark.
     * @dev The performance fee is calculated as a percentage of the profit (asset value increase) since the last high water mark update.
     * @return fee The accrued performance fee in asset units.
     */
    // We're not using the timestamp for comparisions
    // slither-disable-next-line timestamp
    function accruedPerformanceFee() public view returns (uint256 fee) {
        // Calculate the share value in assets
        uint256 shareValue = convertToAssets(1e18);
        // Only calculate if a performance fee is set and the share value exceeds the high water mark
        if (fees.performanceFee.length > 0 && shareValue > highWaterMark) {
            fee = MultiStrategyVaultHelper.calculateTieredFee(shareValue, highWaterMark, totalSupply(), fees);
        }
    }

    /**
     * @notice Retrieves the current fee structure of the vault.
     * @dev Returns the vault's fees including deposit, withdrawal, protocol, and performance fees.
     * @return A `VaultFees` struct containing the current fee rates.
     */
    function getVaultFees() public view returns (VaultFees memory) {
        return fees;
    }

    // ============== FEE LOGIC ===================

    /**
     * @notice Placeholder function for taking portfolio and protocol fees.
     * @dev This function is intended to be overridden with actual fee-taking logic.
     */
    function takePortfolioAndProtocolFees() external nonReentrant takeFees {
        // Intentionally left blank for override
    }

    /**
     * @notice Updates the vault's fee structure.
     * @dev Can only be called by the vault owner. Emits an event upon successful update.
     * @param newFees_ The new fee structure to apply to the vault.
     */
    function setVaultFees(VaultFees calldata newFees_) external takeFees onlyOwner {
        fees = newFees_; // Update the fee structure
        feesUpdatedAt = block.timestamp; // Record the time of the fee update
    }

    /**
     * @notice Sets a new fee recipient address for the vault.
     * @dev Can only be called by the vault owner. Reverts if the new recipient address is the zero address.
     * @param newRecipient_ The address of the new fee recipient.
     */
    function setFeeRecipient(address newRecipient_) external onlyOwner {
        // Validate the new recipient address
        if (newRecipient_ == address(0)) revert InvalidFeeRecipient();

        // Emit an event for the fee recipient update
        emit FeeRecipientUpdated(feeRecipient, newRecipient_);

        feeRecipient = newRecipient_; // Update the fee recipient
    }

    /**
     * @notice Sets a new fee recipient address for the vault.
     * @dev Can only be called by the vault owner. Reverts if the new recipient address is the zero address.
     * @param withdrawalQueue_ The address of the new withdrawlQueue.
     */
    function setWithdrawalQueue(address withdrawalQueue_) external onlyOwner {
        // Validate the new recipient address
        if (withdrawalQueue_ == address(0)) revert InvalidWithdrawlQueue();
        if (address(withdrawalQueue) != address(0)) {
            if (withdrawalQueue.unfinalizedAmount() != 0) revert UnfinalizedWithdrawl(address(withdrawalQueue));
        }
        // Emit an event for the fee recipient update
        emit WithdrawalQueueUpdated(address(withdrawalQueue), withdrawalQueue_);

        withdrawalQueue = IWithdrawalQueue(withdrawalQueue_); // Update the fee recipient
    }
    // ============= STRATEGIES ===================
    /**
     * @notice Retrieves the current strategies employed by the vault.
     * @dev Returns an array of `Strategy` structs representing each strategy.
     * @return An array of `Strategy` structs.
     */

    function getStrategies() external view returns (Strategy[] memory) {
        return strategies;
    }

    /**
     * @notice Toggles the vault's idle state.
     * @dev Can only be called by the vault owner. Emits a `ToggleVaultIdle` event with the previous and new state.
     */
    function toggleVaultIdle() external onlyOwner {
        emit ToggleVaultIdle(vaultIdle, !vaultIdle);
        vaultIdle = !vaultIdle;
    }

    /**
     * @notice Adds a new strategy or replaces an existing one.
     * @dev Can only be called by the vault owner. Validates the total allocation does not exceed 100%.
     *      Emits a `StrategyAdded` or/and `StrategyRemoved` event.
     * @param index_ The index at which to add or replace the strategy. If replacing, this is the index of the existing strategy.
     * @param replace_ A boolean indicating whether to replace an existing strategy.
     * @param newStrategy_ The new strategy to add or replace the existing one with.
     */
    // slither didn't detect the nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function addStrategy(
        uint256 index_,
        bool replace_,
        Strategy calldata newStrategy_
    ) external nonReentrant onlyOwner takeFees {
        IStrategy newStrategy;
        IStrategy removedStrategy;
        (protectStrategy, newStrategy, removedStrategy) = MultiStrategyVaultHelper.addOrReplaceStrategy(
            strategies,
            newStrategy_,
            replace_,
            index_,
            protectStrategy,
            IERC20(asset())
        );
        if (address(removedStrategy) != address(0)) emit StrategyRemoved(address(removedStrategy));
        emit StrategyAdded(address(newStrategy));
    }

    /**
     * @notice Adds a new strategy or replaces an existing one.
     * @dev Can only be called by the vault owner. Validates that the index to be removed exists.
     *      Emits a `StrategyRemoved` event.
     * @param index_ The index of the strategy to be removed.
     */
    // slither didn't detect the nonReentrant modifier
    // slither-disable-next-line reentrancy-no-eth
    function removeStrategy(uint256 index_) external nonReentrant onlyOwner takeFees {
        uint256 len = strategies.length;
        if (index_ >= len) revert InvalidIndex(index_);

        IStrategy stratToBeRemoved = strategies[index_].strategy;
        protectStrategy = MultiStrategyVaultHelper.removeStrategy(stratToBeRemoved, protectStrategy, IERC20(asset()));
        emit StrategyRemoved(address(stratToBeRemoved));

        strategies[index_] = strategies[len - 1];
        strategies.pop();
    }

    /**
     * @notice ERC20 _update function override.
     */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) updateUserRewardsToCurrent(from);
        if (to != address(0)) updateUserRewardsToCurrent(to);
        super._update(from, to, value);
    }

    /**
     * @notice Changes strategies allocations.
     * @dev Can only be called by the vault owner. Validates the total allocation does not exceed 100% and the length corresponds with the strategies array.
     *      Emits a `StrategyAllocationsChanged`
     * @param allocations_ The array with the new allocations.
     * @param redistribute A boolean indicating whether to redistributes allocations.
     */
    function changeAllocations(
        Allocation[] calldata allocations_,
        bool redistribute
    ) external nonReentrant onlyOwner takeFees {
        uint256 len = allocations_.length;

        if (len != strategies.length) revert InvalidLength(len, strategies.length);

        uint256 allotmentTotals = 0;
        for (uint256 i; i < len; ) {
            allotmentTotals += allocations_[i].amount;
            strategies[i].allocation = allocations_[i];
            unchecked {
                i++;
            }
        }
        if (allotmentTotals != 10000) revert AllotmentTotalTooHigh();

        if (redistribute) {
            pullFundsFromStrategies();
            pushFundsToStrategies();
        }

        emit StrategyAllocationsChanged(allocations_);
    }

    /**
     * @notice Pushes funds from the vault into all strategies based on their allocation.
     * @dev Can only be called by the vault owner. Reverts if the vault is idle.
     */
    function pushFundsToStrategies() public onlyOwner {
        if (vaultIdle) revert VaultIsIdle();
        uint256 _totalAssets = IERC20(asset()).balanceOf(address(this));

        // Call the library function to distribute assets
        MultiStrategyVaultHelper.distributeAssetsToStrategies(strategies, _totalAssets);
    }

    /**
     * @notice Pulls funds back from all strategies into the vault.
     * @dev Can only be called by the vault owner.
     */
    // We are aware that we aren't using the return value
    // We control both the length of the array and the external call
    //slither-disable-next-line unused-return,calls-loop
    function pullFundsFromStrategies() public onlyOwner {
        uint256 len = strategies.length;

        for (uint256 i; i < len; ) {
            pullFundsFromSingleStrategy(i);
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Pulls funds back from a single strategy into the vault.
     * @dev Can only be called by the vault owner.
     * @param index_ The index of the strategy from which to pull funds.
     */

    // We are aware that we aren't using the return value
    // We control both the length of the array and the external call
    //slither-disable-next-line unused-return,calls-loop
    function pullFundsFromSingleStrategy(uint256 index_) public onlyOwner {
        IStrategy strategy = strategies[index_].strategy;
        // slither-disable-next-line unused-return
        if (strategy.getAvailableAssetsForWithdrawal() != strategy.totalAssets()) {
            strategy.withdraw(strategy.getAvailableAssetsForWithdrawal(), address(this), address(this));
            return;
        }
        strategy.redeem(strategy.balanceOf(address(this)), address(this), address(this));
    }

    /**
     * @notice Pushes funds from the vault into a single strategy based on its allocation.
     * @dev Can only be called by the vault owner. Reverts if the vault is idle.
     * @param index_ The index of the strategy into which to push funds.
     */
    function pushFundsIntoSingleStrategy(uint256 index_) external onlyOwner {
        uint256 _totalAssets = IERC20(asset()).balanceOf(address(this));

        if (index_ >= strategies.length) revert InvalidIndex(index_);

        if (vaultIdle) revert VaultIsIdle();
        Strategy memory strategy = strategies[index_];
        // slither-disable-next-line unused-return
        strategy.strategy.deposit(
            _totalAssets.mulDiv(strategy.allocation.amount, MAX_BASIS_POINTS, Math.Rounding.Floor),
            address(this)
        );
    }

    /**
     * @notice Pushes the amount sent from the vault into a single strategy.
     * @dev Can only be called by the vault owner. Reverts if the vault is idle.
     * @param index_ The index of the strategy into which to push funds.
     * @param amount The index of the strategy into which to push funds.
     */
    function pushFundsIntoSingleStrategy(uint256 index_, uint256 amount) external onlyOwner {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultFunds(address(this), amount, balance);
        if (vaultIdle) revert VaultIsIdle();
        // slither-disable-next-line unused-return
        strategies[index_].strategy.deposit(amount, address(this));
    }

    /**
     * @notice Sets a new deposit limit for the vault.
     * @dev Can only be called by the vault owner. Emits a `DepositLimitSet` event with the new limit.
     * @param newLimit_ The new deposit limit to set.
     */
    function setDepositLimit(uint256 newLimit_) external onlyOwner {
        depositLimit = newLimit_;
        emit DepositLimitSet(newLimit_);
    }

    /**
     * @notice Harvest rewards on every strategy.
     * @dev Calculates de reward index for each reward found.
     */
    //we control the external call
    //slither-disable-next-line unused-return,calls-loop,reentrancy-no-eth
    function harvestRewards(bytes memory encodedData) external onlyOwner nonReentrant {
        uint256[] memory indices;
        bytes[] memory data;
        if (encodedData.length != 0) {
            (indices, data) = abi.decode(encodedData, (uint256[], bytes[]));
        }
        uint256 totalSupply = totalSupply();
        bytes memory rewardsData;
        for (uint256 i; i < strategies.length; ) {
            //We control both the length of the array and the external call
            //slither-disable-next-line unused-return,calls-loop
            for (uint256 k = 0; k < indices.length; k++) {
                if (indices[k] == i) {
                    rewardsData = data[k];
                    break;
                }
                rewardsData = "";
            }
            ReturnedRewards[] memory returnedRewards = strategies[i].strategy.harvestRewards(rewardsData);

            for (uint256 j; j < returnedRewards.length; ) {
                uint256 amount = returnedRewards[j].rewardAmount;
                address rewardToken = returnedRewards[j].rewardAddress;
                if (amount != 0) {
                    if (rewardIndex[rewardToken] == 0) rewardAddresses.push(rewardToken);
                    rewardIndex[rewardToken] += amount.mulDiv(PRECISION, totalSupply, Math.Rounding.Floor);
                }
                unchecked {
                    j++;
                }
            }
            unchecked {
                i++;
            }
        }
        emit RewardsHarvested();
    }

    /**
     * @notice Updates the user rewards to the current reward index.
     * @dev Calculates the rewards to be transferred to the user based on the difference between the current and previous reward indexes.
     * @param userAddress The address of the user to update rewards for.
     */
    //slither-disable-next-line unused-return,calls-loop,reentrancy-no-eth
    function updateUserRewardsToCurrent(address userAddress) private {
        //retrieves user balance in shares
        uint256 userBalance = balanceOf(userAddress);
        uint256 len = rewardAddresses.length;
        for (uint256 i; i < len; ) {
            uint256 tokenRewardIndex = rewardIndex[rewardAddresses[i]];
            if (userBalance != 0) {
                uint256 rewardsToTransfer = (tokenRewardIndex - userRewardIndex[userAddress][rewardAddresses[i]])
                    .mulDiv(userBalance, PRECISION, Math.Rounding.Floor);
                if (rewardsToTransfer != 0) {
                    totalRewardsClaimed[userAddress][rewardAddresses[i]] += rewardsToTransfer;
                    IERC20(rewardAddresses[i]).safeTransfer(userAddress, rewardsToTransfer);
                }
            }
            userRewardIndex[userAddress][rewardAddresses[i]] = tokenRewardIndex;
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Claims multiple withdrawal requests starting from the lasFinalizedRequestId.
     * @dev This function allows the contract owner to claim multiple withdrawal requests in batches.
     * @param maxRequests The maximum number of withdrawal requests to be processed in this batch.
     */
    function batchClaimWithdrawal(uint256 maxRequests) external onlyOwner nonReentrant {
        if (address(withdrawalQueue) == address(0)) revert QueueNotSet();
        uint256 availableAssets = getAvailableAssetsForWithdrawal();

        uint256 lastFinalizedId = withdrawalQueue.getLastFinalizedRequestId();
        uint256 lastCreatedId = withdrawalQueue.getLastRequestId();
        uint256 newLastFinalized = lastFinalizedId;

        uint256 max = lastCreatedId < lastFinalizedId + maxRequests ? lastCreatedId : lastFinalizedId + maxRequests;

        for (uint256 i = lastFinalizedId + 1; i <= max; ) {
            uint256 newAvailiableAssets = claimWithdrawal(i, availableAssets);
            // slither-disable-next-line incorrect-equality
            if (newAvailiableAssets == availableAssets) break;

            availableAssets = newAvailiableAssets;
            newLastFinalized = i;
            unchecked {
                i++;
            }
        }

        if (newLastFinalized != lastFinalizedId) {
            withdrawalQueue._finalize(newLastFinalized);
        }
    }

    function claimRewards() external {
        updateUserRewardsToCurrent(msg.sender);
    }

    /**
     * @notice Requests funds from available assets.
     * @dev This function allows the protect strategy to request funds from available assets, withdraws from other strategies if necessary,
     * and deposits the requested funds into the protect strategy.
     * @param amount The amount of funds to request.
     */
    //we control the external call, only callable by the protect strategy
    //slither-disable-next-line calls-loop,,reentrancy-events
    function requestFunds(uint256 amount) external onlyProtect {
        uint256 acumulated = MultiStrategyVaultHelper.withdrawAssets(asset(), amount, protectStrategy, strategies);

        //after requesting funds deposits them into the protect strategy
        if (acumulated < amount) {
            revert InsufficientFunds(IStrategy(address(this)), amount, acumulated);
        }
        //slither-disable-next-line unused-return
        IStrategy(protectStrategy).deposit(amount, address(this));
        emit RequestedFunds(protectStrategy, amount);
    }

    // Helper function ////////////////////////

    function _validateAndUpdateDepositTimestamps(address receiver_) private {
        if (receiver_ == address(0)) revert InvalidRecipient();
        if (totalSupply() == 0) feesUpdatedAt = block.timestamp;

        if (firstDeposit == 0) {
            firstDeposit = block.timestamp;
        }
    }
}