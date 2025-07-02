// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title LiquidityMining
 * @notice Rewards liquidity providers with tokens based on their share of the pool
 * @dev Extension for the StableSwap pool to incentivize liquidity provision
 * @author MahmoudKebbi
 */
contract LiquidityMining is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Staking token (LP token)
    IERC20 public immutable stakingToken;

    // Reward token
    IERC20 public immutable rewardToken;

    // Reward rate per second
    uint256 public rewardRate;

    // Last update time
    uint256 public lastUpdateTime;

    // Reward per token stored
    uint256 public rewardPerTokenStored;

    // User reward per token paid
    mapping(address => uint256) public userRewardPerTokenPaid;

    // User rewards
    mapping(address => uint256) public rewards;

    // Total staked amount
    uint256 public totalSupply;

    // Balances of users
    mapping(address => uint256) public balanceOf;

    // Reward period end time
    uint256 public periodFinish;

    // Reward duration
    uint256 public rewardsDuration = 7 days;

    // Precision for calculations
    uint256 private constant PRECISION = 1e18;

    // Custom errors
    error ZeroAmount();
    error RewardTooHigh();
    error RewardPeriodNotComplete();

    // Events
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);

    /**
     * @notice Constructor for the liquidity mining contract
     * @param _stakingToken The LP token address
     * @param _rewardToken The reward token address
     */
    constructor(
        address _stakingToken,
        address _rewardToken
    ) Ownable(msg.sender) {
        stakingToken = IERC20(_stakingToken);
        rewardToken = IERC20(_rewardToken);
    }

    /**
     * @notice Updates reward variables
     * @dev Updates rewardPerTokenStored and lastUpdateTime
     */
    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /**
     * @notice Returns the last time rewards were applicable
     * @return The minimum of current time and period finish
     */
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /**
     * @notice Returns the reward per token
     * @return The current reward per token value
     */
    function rewardPerToken() public view returns (uint256) {
        if (totalSupply == 0) {
            return rewardPerTokenStored;
        }

        return
            rewardPerTokenStored +
            (((lastTimeRewardApplicable() - lastUpdateTime) *
                rewardRate *
                PRECISION) / totalSupply);
    }

    /**
     * @notice Returns the amount of rewards earned by an account
     * @param account The address to check
     * @return The amount of rewards earned
     */
    function earned(address account) public view returns (uint256) {
        return
            ((balanceOf[account] *
                (rewardPerToken() - userRewardPerTokenPaid[account])) /
                PRECISION) + rewards[account];
    }

    /**
     * @notice Stake tokens to earn rewards
     * @param amount Amount of LP tokens to stake
     */
    function stake(
        uint256 amount
    ) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Withdraw staked tokens
     * @param amount Amount of LP tokens to withdraw
     */
    function withdraw(
        uint256 amount
    ) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();

        totalSupply -= amount;
        balanceOf[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Claim accumulated rewards
     */
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /**
     * @notice Exit the system, withdrawing all staked tokens and claiming rewards
     */
    function exit() external {
        withdraw(balanceOf[msg.sender]);
        getReward();
    }

    /**
     * @notice Notifies the contract of a reward addition
     * @param reward Amount of reward tokens to distribute
     */
    function notifyRewardAmount(
        uint256 reward
    ) external onlyOwner updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        uint256 balance = rewardToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(reward);
    }

    /**
     * @notice Updates the duration of the rewards
     * @param _rewardsDuration New rewards duration
     */
    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        if (block.timestamp <= periodFinish) revert RewardPeriodNotComplete();
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardsDuration);
    }

    /**
     * @notice Get detailed staking information for an account
     * @param account The address to check
     * @return _balance Staked balance
     * @return _earned Earned rewards
     * @return _rewardRate Current reward rate per second
     * @return _rewardPerToken Current reward per staked token
     */
    function getStakingInfo(
        address account
    )
        external
        view
        returns (
            uint256 _balance,
            uint256 _earned,
            uint256 _rewardRate,
            uint256 _rewardPerToken
        )
    {
        return (
            balanceOf[account],
            earned(account),
            rewardRate,
            rewardPerToken()
        );
    }

    /**
     * @notice Calculate APR based on current reward rate and staked amount
     * @return apr Annual percentage rate in basis points (1% = 100)
     */
    function calculateAPR() external view returns (uint256 apr) {
        if (totalSupply == 0) return 0;

        // Calculate rewards distributed per year
        uint256 rewardsPerYear = rewardRate * 365 days;

        // Get reward token price in terms of staking token (simplified, would use oracle in production)
        uint256 rewardValue = rewardsPerYear;

        // Calculate APR: (yearly rewards / total staked) * 10000 for basis points
        apr = (rewardValue * 10000) / totalSupply;

        return apr;
    }
}
