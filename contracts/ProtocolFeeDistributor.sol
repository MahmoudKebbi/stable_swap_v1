// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProtocolFeeDistributor
 * @notice Time-weighted fee distribution system with protocol revenue preservation
 * @dev Distributes actual trading fees with time-based multipliers
 * @author MahmoudKebbi
 */
contract ProtocolFeeDistributor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Tokens that can be distributed as fees
    address[] public feeTokens;

    // LP token that represents liquidity
    IERC20 public lpToken;

    // Protocol treasury address
    address public treasury;

    // Protocol base fee share (in basis points, 100 = 1%)
    uint256 public protocolBaseShare = 3000; // 30% base for protocol

    // Minimum protocol share that cannot be reduced (in basis points)
    uint256 public minimumProtocolShare = 2000; // 20% minimum for protocol

    // Time commitment tiers (in seconds)
    uint256[] public commitmentTiers;

    // Time multipliers for each tier (in basis points, 10000 = 1x)
    mapping(uint256 => uint256) public tierMultipliers;

    // User deposits
    struct UserDeposit {
        uint256 amount; // LP token amount
        uint256 lockTime; // Time when lock started
        uint256 unlockTime; // Time when lock expires
        uint256 tierIndex; // Index of the commitment tier
        uint256 lastClaimTime; // Last time fees were claimed
    }

    // User deposit tracking
    mapping(address => UserDeposit) public userDeposits;

    // Total LP tokens locked in each tier
    mapping(uint256 => uint256) public tierTotalLocked;

    // Total LP tokens locked across all tiers
    uint256 public totalLocked;

    // Fee tracking for each token
    struct FeeTracker {
        uint256 accumulated; // Total accumulated fees
        uint256 lastDistributionTime; // Last time fees were distributed
        mapping(address => uint256) userClaimed; // Amount claimed by each user
    }

    // Fee trackers for each token
    mapping(address => FeeTracker) public feeTrackers;

    // Events
    event LiquidityLocked(
        address indexed user,
        uint256 amount,
        uint256 duration,
        uint256 tierIndex
    );
    event LiquidityUnlocked(address indexed user, uint256 amount);
    event FeesDistributed(
        address indexed token,
        uint256 protocolAmount,
        uint256 lpAmount
    );
    event FeesClaimed(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    event TierAdded(uint256 duration, uint256 multiplier);
    event TierUpdated(uint256 tierIndex, uint256 duration, uint256 multiplier);
    event ProtocolSharesUpdated(uint256 baseShare, uint256 minimumShare);

    // Custom errors
    error InvalidTier();
    error InvalidAmount();
    error StillLocked();
    error NoFeesToClaim();
    error InvalidToken();
    error InvalidDuration();
    error InvalidShare();
    error InvalidTimeRange();
    error AlreadyInitialized();

    /**
     * @notice Constructor
     * @param _lpToken Address of the LP token
     * @param _feeTokens Array of tokens that will be distributed as fees
     * @param _treasury Address of the protocol treasury
     */
    constructor(
        address _lpToken,
        address[] memory _feeTokens,
        address _treasury
    ) Ownable(msg.sender) {
        lpToken = IERC20(_lpToken);
        feeTokens = _feeTokens;
        treasury = _treasury;

        // Initialize fee trackers
        for (uint256 i = 0; i < _feeTokens.length; i++) {
            feeTrackers[_feeTokens[i]].lastDistributionTime = block.timestamp;
        }
    }

    /**
     * @notice Setup initial commitment tiers
     * @dev Only callable by owner
     * @param _durations Array of lock durations in seconds
     * @param _multipliers Array of multipliers for each duration (in basis points, 10000 = 1x)
     */
    function setupTiers(
        uint256[] calldata _durations,
        uint256[] calldata _multipliers
    ) external onlyOwner {
        if (commitmentTiers.length > 0) revert AlreadyInitialized();
        if (_durations.length != _multipliers.length) revert InvalidTier();
        if (_durations.length == 0) revert InvalidTier();

        for (uint256 i = 0; i < _durations.length; i++) {
            if (_durations[i] == 0) revert InvalidDuration();
            if (_multipliers[i] < 10000) revert InvalidTier(); // Minimum 1x multiplier

            commitmentTiers.push(_durations[i]);
            tierMultipliers[_durations[i]] = _multipliers[i];

            emit TierAdded(_durations[i], _multipliers[i]);
        }
    }

    /**
     * @notice Add a new commitment tier
     * @dev Only callable by owner
     * @param _duration Lock duration in seconds
     * @param _multiplier Multiplier for this duration (in basis points, 10000 = 1x)
     */
    function addTier(
        uint256 _duration,
        uint256 _multiplier
    ) external onlyOwner {
        if (_duration == 0) revert InvalidDuration();
        if (_multiplier < 10000) revert InvalidTier(); // Minimum 1x multiplier

        // Check tier doesn't already exist
        for (uint256 i = 0; i < commitmentTiers.length; i++) {
            if (commitmentTiers[i] == _duration) revert InvalidTier();
        }

        commitmentTiers.push(_duration);
        tierMultipliers[_duration] = _multiplier;

        emit TierAdded(_duration, _multiplier);
    }

    /**
     * @notice Update an existing commitment tier
     * @dev Only callable by owner, only affects new deposits
     * @param _tierIndex Index of the tier to update
     * @param _duration New lock duration in seconds
     * @param _multiplier New multiplier for this duration (in basis points, 10000 = 1x)
     */
    function updateTier(
        uint256 _tierIndex,
        uint256 _duration,
        uint256 _multiplier
    ) external onlyOwner {
        if (_tierIndex >= commitmentTiers.length) revert InvalidTier();
        if (_duration == 0) revert InvalidDuration();
        if (_multiplier < 10000) revert InvalidTier(); // Minimum 1x multiplier

        // Update tier
        uint256 oldDuration = commitmentTiers[_tierIndex];
        commitmentTiers[_tierIndex] = _duration;
        tierMultipliers[oldDuration] = 0; // Clear old mapping
        tierMultipliers[_duration] = _multiplier;

        emit TierUpdated(_tierIndex, _duration, _multiplier);
    }

    /**
     * @notice Set protocol fee shares
     * @dev Only callable by owner
     * @param _baseShare Base share for protocol (in basis points, 100 = 1%)
     * @param _minimumShare Minimum share for protocol (in basis points, 100 = 1%)
     */
    function setProtocolShares(
        uint256 _baseShare,
        uint256 _minimumShare
    ) external onlyOwner {
        if (_baseShare > 10000 || _minimumShare > 10000) revert InvalidShare();
        if (_minimumShare > _baseShare) revert InvalidShare();

        protocolBaseShare = _baseShare;
        minimumProtocolShare = _minimumShare;

        emit ProtocolSharesUpdated(_baseShare, _minimumShare);
    }

    /**
     * @notice Lock LP tokens for a specific duration
     * @param _amount Amount of LP tokens to lock
     * @param _duration Duration to lock tokens for (must match a tier)
     */
    function lockLiquidity(
        uint256 _amount,
        uint256 _duration
    ) external nonReentrant {
        if (_amount == 0) revert InvalidAmount();

        // Verify duration matches a tier
        uint256 tierIndex = type(uint256).max;
        for (uint256 i = 0; i < commitmentTiers.length; i++) {
            if (commitmentTiers[i] == _duration) {
                tierIndex = i;
                break;
            }
        }
        if (tierIndex == type(uint256).max) revert InvalidTier();

        // If user already has a deposit, claim fees first
        if (userDeposits[msg.sender].amount > 0) {
            claimAllFees();
        }

        // Transfer LP tokens to this contract
        lpToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Update user deposit
        UserDeposit storage deposit = userDeposits[msg.sender];
        deposit.amount = _amount; // Replace existing deposit if any
        deposit.lockTime = block.timestamp;
        deposit.unlockTime = block.timestamp + _duration;
        deposit.tierIndex = tierIndex;
        deposit.lastClaimTime = block.timestamp;

        // Update tier tracking
        uint256 oldTierIndex = deposit.tierIndex;
        if (oldTierIndex < commitmentTiers.length) {
            tierTotalLocked[oldTierIndex] -= deposit.amount;
        }
        tierTotalLocked[tierIndex] += _amount;

        // Update total locked
        totalLocked += _amount;

        emit LiquidityLocked(msg.sender, _amount, _duration, tierIndex);
    }

    /**
     * @notice Unlock LP tokens after lock period expires
     */
    function unlockLiquidity() external nonReentrant {
        UserDeposit storage deposit = userDeposits[msg.sender];

        if (deposit.amount == 0) revert InvalidAmount();
        if (block.timestamp < deposit.unlockTime) revert StillLocked();

        // Claim any pending fees first
        claimAllFees();

        uint256 amount = deposit.amount;

        // Update tier tracking
        tierTotalLocked[deposit.tierIndex] -= amount;

        // Update total locked
        totalLocked -= amount;

        // Clear user deposit
        deposit.amount = 0;
        deposit.lockTime = 0;
        deposit.unlockTime = 0;
        deposit.tierIndex = 0;

        // Transfer LP tokens back to user
        lpToken.safeTransfer(msg.sender, amount);

        emit LiquidityUnlocked(msg.sender, amount);
    }

    /**
     * @notice Distribute fees to protocol treasury and LP providers
     * @param _token Address of the fee token
     * @param _amount Amount of fees to distribute
     */
    function distributeFees(
        address _token,
        uint256 _amount
    ) external nonReentrant {
        bool isValidToken = false;
        for (uint256 i = 0; i < feeTokens.length; i++) {
            if (feeTokens[i] == _token) {
                isValidToken = true;
                break;
            }
        }
        if (!isValidToken) revert InvalidToken();

        // Transfer fees to this contract
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        // Calculate protocol share
        uint256 protocolAmount = (_amount * protocolBaseShare) / 10000;
        uint256 lpAmount = _amount - protocolAmount;

        // Transfer protocol share to treasury
        IERC20(_token).safeTransfer(treasury, protocolAmount);

        // Update fee tracker
        FeeTracker storage tracker = feeTrackers[_token];
        tracker.accumulated += lpAmount;
        tracker.lastDistributionTime = block.timestamp;

        emit FeesDistributed(_token, protocolAmount, lpAmount);
    }

    /**
     * @notice Claim accumulated fees for a specific token
     * @param _token Address of the fee token
     */
    function claimFees(address _token) external nonReentrant {
        _claimFees(msg.sender, _token);
    }

    /**
     * @notice Claim accumulated fees for all tokens
     */
    function claimAllFees() public nonReentrant {
        for (uint256 i = 0; i < feeTokens.length; i++) {
            _claimFees(msg.sender, feeTokens[i]);
        }
    }

    /**
     * @notice Internal function to claim fees for a specific token
     * @param _user Address of the user
     * @param _token Address of the fee token
     */
    function _claimFees(address _user, address _token) internal {
        UserDeposit storage deposit = userDeposits[_user];
        if (deposit.amount == 0) revert InvalidAmount();

        FeeTracker storage tracker = feeTrackers[_token];
        if (tracker.accumulated == 0) revert NoFeesToClaim();

        // Calculate time since last claim
        uint256 timeSinceLastClaim = block.timestamp - deposit.lastClaimTime;

        // Only calculate fees if there's been a meaningful time period
        if (timeSinceLastClaim == 0) return;

        // Get user's tier multiplier
        uint256 tierDuration = commitmentTiers[deposit.tierIndex];
        uint256 tierMultiplier = tierMultipliers[tierDuration];

        // Calculate effective share considering time-weighting and tier multiplier
        uint256 userWeightedShare = (deposit.amount * tierMultiplier) / 10000;

        // Calculate total weighted share
        uint256 totalWeightedShare = 0;
        for (uint256 i = 0; i < commitmentTiers.length; i++) {
            uint256 duration = commitmentTiers[i];
            uint256 multiplier = tierMultipliers[duration];
            totalWeightedShare += (tierTotalLocked[i] * multiplier) / 10000;
        }

        if (totalWeightedShare == 0) return;

        // Calculate user's fee share
        uint256 userShare = (tracker.accumulated * userWeightedShare) /
            totalWeightedShare;

        // Subtract what user has already claimed
        uint256 pendingAmount = userShare - tracker.userClaimed[_user];

        if (pendingAmount == 0) return;

        // Update claimed amount
        tracker.userClaimed[_user] = userShare;

        // Update last claim time
        deposit.lastClaimTime = block.timestamp;

        // Transfer fees to user
        IERC20(_token).safeTransfer(_user, pendingAmount);

        emit FeesClaimed(_user, _token, pendingAmount);
    }

    /**
     * @notice Get pending fees for a user
     * @param _user Address of the user
     * @param _token Address of the fee token
     * @return Amount of fees pending for the user
     */
    function getPendingFees(
        address _user,
        address _token
    ) external view returns (uint256) {
        UserDeposit storage deposit = userDeposits[_user];
        if (deposit.amount == 0) return 0;

        FeeTracker storage tracker = feeTrackers[_token];
        if (tracker.accumulated == 0) return 0;

        // Get user's tier multiplier
        uint256 tierDuration = commitmentTiers[deposit.tierIndex];
        uint256 tierMultiplier = tierMultipliers[tierDuration];

        // Calculate effective share considering tier multiplier
        uint256 userWeightedShare = (deposit.amount * tierMultiplier) / 10000;

        // Calculate total weighted share
        uint256 totalWeightedShare = 0;
        for (uint256 i = 0; i < commitmentTiers.length; i++) {
            uint256 duration = commitmentTiers[i];
            uint256 multiplier = tierMultipliers[duration];
            totalWeightedShare += (tierTotalLocked[i] * multiplier) / 10000;
        }

        if (totalWeightedShare == 0) return 0;

        // Calculate user's fee share
        uint256 userShare = (tracker.accumulated * userWeightedShare) /
            totalWeightedShare;

        // Subtract what user has already claimed
        return userShare - tracker.userClaimed[_user];
    }

    /**
     * @notice Get information about all tiers
     * @return durations Array of lock durations
     * @return multipliers Array of multipliers for each duration
     * @return lockedAmounts Array of total LP tokens locked in each tier
     */
    function getTierInfo()
        external
        view
        returns (
            uint256[] memory durations,
            uint256[] memory multipliers,
            uint256[] memory lockedAmounts
        )
    {
        uint256 tiersCount = commitmentTiers.length;
        durations = new uint256[](tiersCount);
        multipliers = new uint256[](tiersCount);
        lockedAmounts = new uint256[](tiersCount);

        for (uint256 i = 0; i < tiersCount; i++) {
            uint256 duration = commitmentTiers[i];
            durations[i] = duration;
            multipliers[i] = tierMultipliers[duration];
            lockedAmounts[i] = tierTotalLocked[i];
        }

        return (durations, multipliers, lockedAmounts);
    }

    /**
     * @notice Get user deposit information
     * @param _user Address of the user
     * @return amount Amount of LP tokens locked
     * @return lockTime Time when lock started
     * @return unlockTime Time when lock expires
     * @return tierIndex Index of the commitment tier
     * @return tierMultiplier Multiplier for the user's tier
     * @return timeRemaining Time remaining until unlock
     */
    function getUserInfo(
        address _user
    )
        external
        view
        returns (
            uint256 amount,
            uint256 lockTime,
            uint256 unlockTime,
            uint256 tierIndex,
            uint256 tierMultiplier,
            uint256 timeRemaining
        )
    {
        UserDeposit storage deposit = userDeposits[_user];

        uint256 multiplier = 0;
        if (deposit.tierIndex < commitmentTiers.length) {
            uint256 duration = commitmentTiers[deposit.tierIndex];
            multiplier = tierMultipliers[duration];
        }

        uint256 remaining = 0;
        if (block.timestamp < deposit.unlockTime) {
            remaining = deposit.unlockTime - block.timestamp;
        }

        return (
            deposit.amount,
            deposit.lockTime,
            deposit.unlockTime,
            deposit.tierIndex,
            multiplier,
            remaining
        );
    }

    /**
     * @notice Get effective APR for a specific tier based on current fees and total locked
     * @param _tierIndex Index of the tier
     * @return apr Effective APR in basis points (100 = 1%)
     */
    function getEffectiveAPR(
        uint256 _tierIndex
    ) external view returns (uint256 apr) {
        if (_tierIndex >= commitmentTiers.length) revert InvalidTier();

        // Get tier info
        uint256 duration = commitmentTiers[_tierIndex];
        uint256 multiplier = tierMultipliers[duration];
        uint256 tierLocked = tierTotalLocked[_tierIndex];

        if (tierLocked == 0 || totalLocked == 0) return 0;

        // Calculate weighted share
        uint256 weightedShare = (tierLocked * multiplier) / 10000;

        // Calculate total weighted share
        uint256 totalWeightedShare = 0;
        for (uint256 i = 0; i < commitmentTiers.length; i++) {
            uint256 tierDuration = commitmentTiers[i];
            uint256 tierMultiplier = tierMultipliers[tierDuration];
            totalWeightedShare += (tierTotalLocked[i] * tierMultiplier) / 10000;
        }

        if (totalWeightedShare == 0) return 0;

        // Calculate approximate annual fees (based on recent distribution rate)
        uint256 totalAnnualFees = 0;
        for (uint256 i = 0; i < feeTokens.length; i++) {
            address token = feeTokens[i];
            FeeTracker storage tracker = feeTrackers[token];

            // Use a simple extrapolation from recent fees
            uint256 timeSinceLastDistribution = block.timestamp -
                tracker.lastDistributionTime;
            if (timeSinceLastDistribution > 0 && tracker.accumulated > 0) {
                // Estimate annual rate based on recent accumulation
                uint256 annualRate = (tracker.accumulated * 365 days) /
                    timeSinceLastDistribution;
                totalAnnualFees += annualRate;
            }
        }

        if (totalAnnualFees == 0) return 0;

        // Calculate tier's share of annual fees
        uint256 tierAnnualFees = (totalAnnualFees * weightedShare) /
            totalWeightedShare;

        // Calculate APR (annual fees / locked amount * 10000 for basis points)
        apr = (tierAnnualFees * 10000) / tierLocked;

        return apr;
    }
}
