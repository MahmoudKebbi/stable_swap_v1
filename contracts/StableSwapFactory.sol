// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./StableSwapPool.sol";
import "./LPToken.sol";

/**
 * @title StableSwapFactory
 * @notice Factory for creating StableSwap pools with liquidity mining rewards
 * @dev Size-optimized implementation with added staking functionality
 * @author MahmoudKebbi
 * 
 */
contract StableSwapFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant PRECISION = 1e6;
    uint256 private constant MAX_FEE = 1e5;
    uint256 private constant REWARD_PRECISION = 1e18;

    // Fee parameters for new pools
    uint256 public defaultBaseFee;
    uint256 public defaultMinFee;
    uint256 public defaultMaxFee;
    uint256 public defaultVolatilityMultiplier;

    // Protocol fee settings
    address public protocolFeeReceiver;
    uint256 public protocolFeeShare;

    // Pool registry
    mapping(address => mapping(address => address)) public getPool;
    address[] public allPools;

    // Liquidity Mining
    struct RewardInfo {
        IERC20 rewardToken; // Token used for rewards
        uint256 rewardRate; // Rewards per second
        uint256 periodFinish; // Timestamp when rewards end
        uint256 lastUpdateTime; // Last time rewards were distributed
        uint256 rewardPerTokenStored; // Accumulated rewards per token
    }

    struct StakerInfo {
        uint256 balance; // Staked balance
        uint256 rewardPerTokenPaid; // Last recorded reward per token
        uint256 rewards; // Unclaimed rewards
        uint256 lastStakeTime; // Last time user staked/withdrew
    }

    // Pool -> Reward program data
    mapping(address => RewardInfo) public poolRewards;

    // Pool -> User -> Staker info
    mapping(address => mapping(address => StakerInfo)) public userStakes;

    // Pool -> Total staked tokens
    mapping(address => uint256) public totalStaked;

    // Events - Combined to save bytecode
    event PoolCreated(
        address indexed token0,
        address indexed token1,
        address pool,
        address lpToken
    );
    event ParametersUpdated(
        uint256 baseFee,
        uint256 minFee,
        uint256 maxFee,
        uint256 volatilityMultiplier,
        address feeReceiver,
        uint256 feeShare
    );
    event RewardsUpdated(
        address indexed pool,
        address indexed rewardToken,
        uint256 rewardRate,
        uint256 periodFinish
    );
    event Staked(address indexed user, address indexed pool, uint256 amount);
    event Withdrawn(address indexed user, address indexed pool, uint256 amount);
    event RewardPaid(
        address indexed user,
        address indexed pool,
        uint256 reward
    );

    // Custom errors - Combined to save bytecode
    error InvalidParameters();
    error PoolError();
    error RewardError();
    error StakingError();

    /**
     * @notice Constructor for the factory
     * @param _defaultBaseFee Default base fee
     * @param _defaultMinFee Default minimum fee
     * @param _defaultMaxFee Default maximum fee
     * @param _defaultVolatilityMultiplier Default volatility multiplier
     */
    constructor(
        uint256 _defaultBaseFee,
        uint256 _defaultMinFee,
        uint256 _defaultMaxFee,
        uint256 _defaultVolatilityMultiplier
    ) Ownable(msg.sender) {
        _setFeeParameters(
            _defaultBaseFee,
            _defaultMinFee,
            _defaultMaxFee,
            _defaultVolatilityMultiplier
        );
    }

    /**
     * @notice Creates a new StableSwap pool with two-step initialization
     * @param tokenA First token address
     * @param tokenB Second token address
     * @param a Amplification coefficient
     * @return pool Address of the created pool
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint256 a
    ) external returns (address pool) {
        // Validate inputs
        if (tokenA == tokenB || tokenA == address(0) || tokenB == address(0))
            revert PoolError();

        // Sort tokens
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        // Check if pool already exists
        if (getPool[token0][token1] != address(0)) revert PoolError();

        // Create LP token first
        string memory symbol0 = IERC20Metadata(token0).symbol();
        string memory symbol1 = IERC20Metadata(token1).symbol();
        string memory name = string(
            abi.encodePacked("StableSwap LP ", symbol0, "-", symbol1)
        );
        string memory symbol = string(
            abi.encodePacked("LP-", symbol0, "-", symbol1)
        );

        // 1. Create the LP token (initially owned by the factory)
        LPToken lpToken = new LPToken(name, symbol);

        // 2. Create the pool
        StableSwapPool poolContract = new StableSwapPool(
            token0,
            token1,
            address(lpToken),
            a,
            defaultBaseFee,
            defaultMinFee,
            defaultMaxFee,
            defaultVolatilityMultiplier
        );
        pool = address(poolContract);

        // 3. Transfer ownership of LP token to the pool
        lpToken.transferOwnership(pool);

        // 4. Initialize the pool
        poolContract.initialize();

        // 5. Set protocol fee receiver if configured
        if (protocolFeeReceiver != address(0)) {
            poolContract.setProtocolFeeReceiver(
                protocolFeeReceiver,
                protocolFeeShare
            );
        }

        // Register pool
        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool;
        allPools.push(pool);

        emit PoolCreated(token0, token1, pool, address(lpToken));
        return pool;
    }

    /**
     * @notice Internal function to set fee parameters with validation
     */
    function _setFeeParameters(
        uint256 _baseFee,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _volatilityMultiplier
    ) internal {
        // Auto-convert from old precision if needed
        if (_maxFee > PRECISION) {
            _baseFee /= 1e12;
            _minFee /= 1e12;
            _maxFee /= 1e12;
            _volatilityMultiplier /= 1e12;
        }

        if (_maxFee > MAX_FEE || _minFee > _baseFee || _baseFee > _maxFee)
            revert InvalidParameters();

        defaultBaseFee = _baseFee;
        defaultMinFee = _minFee;
        defaultMaxFee = _maxFee;
        defaultVolatilityMultiplier = _volatilityMultiplier;
    }

    /**
     * @notice Set default fee parameters for new pools
     */
    function setDefaultFeeParameters(
        uint256 _baseFee,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _volatilityMultiplier
    ) external onlyOwner {
        _setFeeParameters(_baseFee, _minFee, _maxFee, _volatilityMultiplier);

        emit ParametersUpdated(
            defaultBaseFee,
            defaultMinFee,
            defaultMaxFee,
            defaultVolatilityMultiplier,
            protocolFeeReceiver,
            protocolFeeShare
        );
    }

    /**
     * @notice Set protocol fee receiver and share
     */
    function setProtocolFeeReceiver(
        address _feeReceiver,
        uint256 _feeShare
    ) external onlyOwner {
        if (_feeShare > 5000) revert InvalidParameters();

        protocolFeeReceiver = _feeReceiver;
        protocolFeeShare = _feeShare;

        emit ParametersUpdated(
            defaultBaseFee,
            defaultMinFee,
            defaultMaxFee,
            defaultVolatilityMultiplier,
            _feeReceiver,
            _feeShare
        );
    }

    /**
     * @notice Get the number of pools created
     * @return The number of pools
     */
    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /**
     * @notice Start a liquidity mining program for a specific pool
     * @param pool The pool to distribute rewards for
     * @param rewardToken Token to distribute as rewards
     * @param amount Total amount of tokens to distribute
     * @param duration Duration of the rewards program in seconds
     */
    function startRewards(
        address pool,
        address rewardToken,
        uint256 amount,
        uint256 duration
    ) external onlyOwner {
        // Validate inputs
        if (pool == address(0) || rewardToken == address(0) || duration == 0)
            revert InvalidParameters();

        // Verify this is actually one of our pools
        bool isValidPool = false;
        for (uint i = 0; i < allPools.length; i++) {
            if (allPools[i] == pool) {
                isValidPool = true;
                break;
            }
        }
        if (!isValidPool) revert PoolError();

        // Update reward tracking
        _updateReward(pool, address(0));

        // Setup reward program
        RewardInfo storage rewards = poolRewards[pool];

        // If reward token changes, ensure all previous rewards are distributed
        if (
            address(rewards.rewardToken) != address(0) &&
            address(rewards.rewardToken) != rewardToken
        ) {
            // Ensure previous rewards period is over
            if (block.timestamp < rewards.periodFinish) revert RewardError();
        }

        // Transfer reward tokens to this contract
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate new reward rate (tokens per second)
        uint256 rewardRate = amount / duration;

        // Ensure the reward rate is greater than zero
        if (rewardRate == 0) revert RewardError();

        // Update reward info
        rewards.rewardToken = IERC20(rewardToken);
        rewards.rewardRate = rewardRate;
        rewards.lastUpdateTime = block.timestamp;
        rewards.periodFinish = block.timestamp + duration;

        emit RewardsUpdated(
            pool,
            rewardToken,
            rewardRate,
            rewards.periodFinish
        );
    }

    /**
     * @notice Stake LP tokens to earn rewards
     * @param pool Pool to stake in
     * @param amount Amount of LP tokens to stake
     */
    function stake(address pool, uint256 amount) external nonReentrant {
        // Validate inputs
        if (pool == address(0) || amount == 0) revert InvalidParameters();

        // Update reward tracking
        _updateReward(pool, msg.sender);

        // Transfer LP tokens to this contract
        LPToken lpToken = LPToken(StableSwapPool(pool).lpToken());
        lpToken.transferFrom(msg.sender, address(this), amount);

        // Update staking info
        StakerInfo storage staker = userStakes[pool][msg.sender];
        staker.balance += amount;
        staker.lastStakeTime = block.timestamp;
        totalStaked[pool] += amount;

        emit Staked(msg.sender, pool, amount);
    }

    /**
     * @notice Withdraw staked LP tokens
     * @param pool Pool to withdraw from
     * @param amount Amount of LP tokens to withdraw
     */
    function withdraw(address pool, uint256 amount) external nonReentrant {
        // Validate inputs
        if (pool == address(0)) revert InvalidParameters();

        StakerInfo storage staker = userStakes[pool][msg.sender];
        if (amount > staker.balance) revert StakingError();

        // Update reward tracking
        _updateReward(pool, msg.sender);

        // Update staking info
        staker.balance -= amount;
        staker.lastStakeTime = block.timestamp;
        totalStaked[pool] -= amount;

        // Transfer LP tokens back to user
        LPToken lpToken = LPToken(StableSwapPool(pool).lpToken());
        lpToken.transfer(msg.sender, amount);

        emit Withdrawn(msg.sender, pool, amount);
    }

    /**
     * @notice Claim accumulated rewards
     * @param pool Pool to claim rewards from
     */
    function claimRewards(address pool) external nonReentrant {
        // Update reward tracking
        _updateReward(pool, msg.sender);

        // Get accumulated rewards
        StakerInfo storage staker = userStakes[pool][msg.sender];
        uint256 reward = staker.rewards;

        // Reset rewards
        if (reward > 0) {
            staker.rewards = 0;

            // Transfer rewards to user
            RewardInfo storage rewards = poolRewards[pool];
            rewards.rewardToken.safeTransfer(msg.sender, reward);

            emit RewardPaid(msg.sender, pool, reward);
        }
    }

    /**
     * @notice View function to get pending rewards
     * @param pool Pool to check rewards for
     * @param user User to check rewards for
     * @return Pending reward amount
     */
    function pendingRewards(
        address pool,
        address user
    ) external view returns (uint256) {
        if (pool == address(0) || user == address(0)) return 0;

        StakerInfo storage staker = userStakes[pool][msg.sender];
        RewardInfo storage rewards = poolRewards[pool];

        // If user has no stake or rewards program hasn't started
        if (staker.balance == 0 || address(rewards.rewardToken) == address(0)) {
            return staker.rewards;
        }

        // Calculate current reward per token
        uint256 rewardPerToken = _rewardPerToken(pool);

        // Calculate pending rewards
        uint256 pending = (staker.balance *
            (rewardPerToken - staker.rewardPerTokenPaid)) / REWARD_PRECISION;

        // Add previously accumulated rewards
        return staker.rewards + pending;
    }

    /**
     * @notice Get reward info for a pool
     * @param pool Pool to get reward info for
     * @return rewardToken Reward token address
     * @return rewardRate Rewards per second
     * @return periodFinish Timestamp when rewards end
     * @return totalStakedAmount Total LP tokens staked in the pool
     */
    function getRewardInfo(
        address pool
    )
        external
        view
        returns (
            address rewardToken,
            uint256 rewardRate,
            uint256 periodFinish,
            uint256 totalStakedAmount
        )
    {
        RewardInfo storage rewards = poolRewards[pool];
        return (
            address(rewards.rewardToken),
            rewards.rewardRate,
            rewards.periodFinish,
            totalStaked[pool]
        );
    }

    /**
     * @notice Get staking info for a user in a pool
     * @param pool Pool to check
     * @param user User to check
     * @return stakedAmount Amount of LP tokens staked
     * @return pendingReward Pending reward amount
     * @return lastStakeTime Last time user staked/withdrew
     */
    function getUserStakeInfo(
        address pool,
        address user
    )
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 pendingReward,
            uint256 lastStakeTime
        )
    {
        StakerInfo storage staker = userStakes[pool][user];

        // Calculate pending rewards
        uint256 pending = 0;
        if (staker.balance > 0) {
            uint256 rewardPerToken = _rewardPerToken(pool);
            pending =
                (staker.balance *
                    (rewardPerToken - staker.rewardPerTokenPaid)) /
                REWARD_PRECISION +
                staker.rewards;
        } else {
            pending = staker.rewards;
        }

        return (staker.balance, pending, staker.lastStakeTime);
    }

    /**
     * @notice Calculate the current reward per staked token
     * @param pool Pool to calculate for
     * @return Current reward per token rate
     */
    function _rewardPerToken(address pool) internal view returns (uint256) {
        RewardInfo storage rewards = poolRewards[pool];

        // If no LP tokens are staked or program hasn't started
        if (
            totalStaked[pool] == 0 || address(rewards.rewardToken) == address(0)
        ) {
            return rewards.rewardPerTokenStored;
        }

        // Calculate time since last update
        uint256 endTime = block.timestamp < rewards.periodFinish
            ? block.timestamp
            : rewards.periodFinish;
        uint256 timeElapsed = endTime > rewards.lastUpdateTime
            ? endTime - rewards.lastUpdateTime
            : 0;

        // Calculate additional rewards per token
        if (timeElapsed == 0) {
            return rewards.rewardPerTokenStored;
        }

        uint256 additionalRewardPerToken = (timeElapsed *
            rewards.rewardRate *
            REWARD_PRECISION) / totalStaked[pool];

        return rewards.rewardPerTokenStored + additionalRewardPerToken;
    }

    /**
     * @notice Update reward calculations for a pool and user
     * @param pool Pool to update
     * @param user User to update (0x0 for pool-wide update only)
     */
    function _updateReward(address pool, address user) internal {
        RewardInfo storage rewards = poolRewards[pool];

        // Update pool-wide reward tracking
        rewards.rewardPerTokenStored = _rewardPerToken(pool);
        rewards.lastUpdateTime = block.timestamp < rewards.periodFinish
            ? block.timestamp
            : rewards.periodFinish;

        // If updating for a specific user
        if (user != address(0)) {
            StakerInfo storage staker = userStakes[pool][user];

            // Calculate and update user's rewards
            if (staker.balance > 0) {
                uint256 pendingReward = (staker.balance *
                    (rewards.rewardPerTokenStored -
                        staker.rewardPerTokenPaid)) / REWARD_PRECISION;

                staker.rewards += pendingReward;
            }

            // Update user's reward per token paid
            staker.rewardPerTokenPaid = rewards.rewardPerTokenStored;
        }
    }

    /**
     * @notice Emergency function to recover tokens mistakenly sent to this contract
     * @param token Token to recover
     * @param amount Amount to recover
     * @param to Address to send recovered tokens to
     */
    function recoverToken(
        address token,
        uint256 amount,
        address to
    ) external onlyOwner {
        // Ensure we're not stealing staked LP tokens or active reward tokens
        bool isActiveRewardToken = false;

        for (uint i = 0; i < allPools.length; i++) {
            address pool = allPools[i];

            // Check if it's an LP token
            if (token == address(StableSwapPool(pool).lpToken())) {
                // Ensure we're not recovering staked tokens
                if (
                    amount >
                    IERC20(token).balanceOf(address(this)) - totalStaked[pool]
                ) {
                    revert StakingError();
                }
            }

            // Check if it's an active reward token
            RewardInfo storage rewards = poolRewards[pool];
            if (
                token == address(rewards.rewardToken) &&
                block.timestamp < rewards.periodFinish
            ) {
                isActiveRewardToken = true;
            }
        }

        // Don't allow recovering active reward tokens
        if (isActiveRewardToken) revert RewardError();

        // Recover the tokens
        IERC20(token).safeTransfer(to, amount);
    }
}
