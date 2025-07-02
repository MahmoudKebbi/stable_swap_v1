// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StableSwapPool.sol";
import "./LPToken.sol";
import "./LiquidityMining.sol";

/**
 * @title StableSwapFactory
 * @notice Factory contract for creating StableSwap pools with optional liquidity mining
 * @author MahmoudKebbi
 */
contract StableSwapFactory is Ownable {
    using SafeERC20 for IERC20;

    // Mapping of pool address to boolean indicating if it was created by this factory
    mapping(address => bool) public isPoolFromFactory;

    // Array of all pools created
    address[] public allPools;

    // Mapping of token pair to pool address
    mapping(address => mapping(address => address)) public getPool;

    // Mapping of pool to liquidity mining contract
    mapping(address => address) public getPoolLiquidityMining;

    // Protocol fee collector
    address public feeCollector;

    // Protocol fee share (in basis points, 100 = 1%)
    uint256 public protocolFeeShare = 0; // Initially 0%

    // Default fee parameters
    uint256 public defaultAmplification = 100 * 100; // A = 100
    uint256 public defaultBaseFee = 4e14; // 0.04%
    uint256 public defaultMinFee = 1e14; // 0.01%
    uint256 public defaultMaxFee = 1e16; // 1%
    uint256 public defaultVolatilityMultiplier = 1e17; // Scaling factor

    // Custom errors
    error PoolAlreadyExists();
    error PoolDoesNotExist();
    error IdenticalAddresses();
    error InvalidFeeShare();

    // Events
    event PoolCreated(
        address indexed pool,
        address token0,
        address token1,
        address lpToken
    );
    event LiquidityMiningDeployed(
        address indexed pool,
        address liquidityMining,
        address rewardToken
    );
    event FeeCollectorSet(address feeCollector);
    event ProtocolFeeShareSet(uint256 protocolFeeShare);
    event DefaultParametersSet(
        uint256 amplification,
        uint256 baseFee,
        uint256 minFee,
        uint256 maxFee,
        uint256 volatilityMultiplier
    );

    /**
     * @notice Constructor for the factory
     */
    constructor() Ownable(msg.sender) {
        feeCollector = msg.sender;
    }

    /**
     * @notice Creates a new StableSwap pool
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @return pool Address of the created pool
     */
    function createPool(
        address token0,
        address token1
    ) external returns (address pool) {
        return
            _createPool(
                token0,
                token1,
                defaultAmplification,
                defaultBaseFee,
                defaultMinFee,
                defaultMaxFee,
                defaultVolatilityMultiplier
            );
    }

    /**
     * @notice Creates a new StableSwap pool with custom parameters
     * @param token0 Address of the first token
     * @param token1 Address of the second token
     * @param a Amplification coefficient
     * @param baseFee Base swap fee
     * @param minFee Minimum swap fee
     * @param maxFee Maximum swap fee
     * @param volatilityMultiplier Volatility to fee multiplier
     * @return pool Address of the created pool
     */
    function createPoolWithCustomParameters(
        address token0,
        address token1,
        uint256 a,
        uint256 baseFee,
        uint256 minFee,
        uint256 maxFee,
        uint256 volatilityMultiplier
    ) external returns (address pool) {
        return
            _createPool(
                token0,
                token1,
                a,
                baseFee,
                minFee,
                maxFee,
                volatilityMultiplier
            );
    }

    /**
     * @notice Internal function to create a pool
     */
    function _createPool(
        address tokenA,
        address tokenB,
        uint256 a,
        uint256 baseFee,
        uint256 minFee,
        uint256 maxFee,
        uint256 volatilityMultiplier
    ) internal returns (address pool) {
        if (tokenA == tokenB) revert IdenticalAddresses();

        // Sort tokens to ensure deterministic pool addresses
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        // Check if pool already exists
        if (getPool[token0][token1] != address(0)) revert PoolAlreadyExists();

        // Create LP token
        string memory lpName = string(
            abi.encodePacked(
                "StableSwap LP ",
                ERC20(token0).symbol(),
                "-",
                ERC20(token1).symbol()
            )
        );
        string memory lpSymbol = string(
            abi.encodePacked(
                "sLP-",
                ERC20(token0).symbol(),
                "-",
                ERC20(token1).symbol()
            )
        );
        LPToken lpToken = new LPToken(lpName, lpSymbol, address(this));

        // Create pool
        StableSwapPool newPool = new StableSwapPool(
            token0,
            token1,
            address(lpToken),
            a,
            baseFee,
            minFee,
            maxFee,
            volatilityMultiplier
        );

        // Transfer LP token ownership to the pool
        lpToken.transferOwnership(address(newPool));

        // Register the pool
        pool = address(newPool);
        isPoolFromFactory[pool] = true;
        getPool[token0][token1] = pool;
        getPool[token1][token0] = pool; // Add the reverse mapping too
        allPools.push(pool);

        // Configure protocol fee if set
        if (protocolFeeShare > 0 && feeCollector != address(0)) {
            newPool.setProtocolFeeReceiver(feeCollector, protocolFeeShare);
        }

        // Transfer pool ownership to msg.sender
        newPool.transferOwnership(msg.sender);

        emit PoolCreated(pool, token0, token1, address(lpToken));
        return pool;
    }

    /**
     * @notice Deploy a liquidity mining contract for an existing pool
     * @param pool Address of the StableSwap pool
     * @param rewardToken Address of the reward token
     * @return liquidityMining Address of the liquidity mining contract
     */
    function deployLiquidityMining(
        address pool,
        address rewardToken
    ) external returns (address liquidityMining) {
        if (!isPoolFromFactory[pool]) revert PoolDoesNotExist();

        StableSwapPool poolContract = StableSwapPool(pool);
        address lpToken = address(poolContract.lpToken());

        // Create liquidity mining contract
        LiquidityMining mining = new LiquidityMining(lpToken, rewardToken);

        // Transfer ownership to caller
        mining.transferOwnership(msg.sender);

        liquidityMining = address(mining);
        getPoolLiquidityMining[pool] = liquidityMining;

        emit LiquidityMiningDeployed(pool, liquidityMining, rewardToken);
        return liquidityMining;
    }

    /**
     * @notice Set the fee collector address
     * @param _feeCollector Address that will receive protocol fees
     */
    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = _feeCollector;
        emit FeeCollectorSet(_feeCollector);
    }

    /**
     * @notice Set the protocol fee share
     * @param _protocolFeeShare Fee share in basis points (100 = 1%)
     */
    function setProtocolFeeShare(uint256 _protocolFeeShare) external onlyOwner {
        if (_protocolFeeShare > 5000) revert InvalidFeeShare(); // Max 50%
        protocolFeeShare = _protocolFeeShare;
        emit ProtocolFeeShareSet(_protocolFeeShare);
    }

    /**
     * @notice Set default parameters for new pools
     * @param _amplification Default amplification coefficient
     * @param _baseFee Default base fee
     * @param _minFee Default minimum fee
     * @param _maxFee Default maximum fee
     * @param _volatilityMultiplier Default volatility multiplier
     */
    function setDefaultParameters(
        uint256 _amplification,
        uint256 _baseFee,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _volatilityMultiplier
    ) external onlyOwner {
        defaultAmplification = _amplification;
        defaultBaseFee = _baseFee;
        defaultMinFee = _minFee;
        defaultMaxFee = _maxFee;
        defaultVolatilityMultiplier = _volatilityMultiplier;

        emit DefaultParametersSet(
            _amplification,
            _baseFee,
            _minFee,
            _maxFee,
            _volatilityMultiplier
        );
    }

    /**
     * @notice Returns the number of pools created by this factory
     * @return The number of pools
     */
    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    /**
     * @notice Get pool analytics
     * @param pool Address of the pool
     * @return _tokens Array of token addresses
     * @return _balances Array of token balances
     * @return _liquidity Total liquidity (in terms of invariant)
     * @return _fee Current fee
     * @return _amplification Current amplification coefficient
     */
    function getPoolAnalytics(
        address pool
    )
        external
        view
        returns (
            address[2] memory _tokens,
            uint256[2] memory _balances,
            uint256 _liquidity,
            uint256 _fee,
            uint256 _amplification
        )
    {
        if (!isPoolFromFactory[pool]) revert PoolDoesNotExist();

        StableSwapPool poolContract = StableSwapPool(pool);

        _tokens[0] = address(poolContract.token0());
        _tokens[1] = address(poolContract.token1());

        _balances[0] = poolContract.balances(0);
        _balances[1] = poolContract.balances(1);

        _liquidity = poolContract.lpToken().totalSupply();
        _fee = poolContract.calculateDynamicFee();
        _amplification = poolContract.getA();

        return (_tokens, _balances, _liquidity, _fee, _amplification);
    }
}
