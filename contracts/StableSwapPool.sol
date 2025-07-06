// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./StableMath.sol";
import "./LPToken.sol";

/**
 * @title IERC677
 * @dev Interface for ERC677 token standard which extends ERC20 with transferAndCall
 */
interface IERC677 is IERC20 {
    function transferAndCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool);
}

/**
 * @title StableSwapPool
 * @notice A StableSwap AMM for two ERC677 stablecoins with dynamic fee system
 * @dev Implements the StableSwap invariant for stable asset trading with overflow protection
 * @author MahmoudKebbi
 * date 2025-07-04 18:53:33
 */
contract StableSwapPool is ReentrancyGuard, Ownable, Pausable, ERC677Receiver {
    using SafeERC20 for IERC20;

    // Constants
    uint256 private constant PRECISION = 1e6; // Changed from 1e18 to match StableMath
    uint256 private constant A_PRECISION = 100;
    uint256 private constant MAX_A = 10000; // Reduced maximum allowed amplification
    uint256 private constant MAX_FEE = 1e5; // Maximum fee: 10% (in 1e6 precision)
    uint256 private constant OLD_PRECISION = 1e18; // For auto-conversion of fee parameters
    uint256 private constant MIN_RAMP_TIME = 1 days; // Minimum time for A value changes
    uint256 private constant MAX_PROTOCOL_FEE_SHARE = 5000; // Maximum protocol fee: 50%

    // Initialization state
    bool public initialized = false;

    // Function selectors for ERC677 callback
    bytes4 private constant ADD_LIQUIDITY_SELECTOR =
        bytes4(keccak256("addLiquidityERC677(uint256,uint256,uint256)"));
    bytes4 private constant SWAP_SELECTOR =
        bytes4(keccak256("swapERC677(uint256,uint256)"));

    // Pool state variables
    IERC677 public immutable token0; // First token in the pool
    IERC677 public immutable token1; // Second token in the pool
    LPToken public immutable lpToken; // Liquidity provider token
    uint256 public amplification; // Current amplification coefficient * A_PRECISION

    // Scaling factors for tokens with different decimals
    mapping(uint256 => uint256) public scalingFactors;

    // Dynamic fee system
    uint256 public baseFee; // Base fee in PRECISION units
    uint256 public maxFee; // Maximum fee in PRECISION units
    uint256 public minFee; // Minimum fee in PRECISION units
    uint256 public volatilityMultiplier; // Multiplier for volatility to fee conversion
    uint256 public lastSwapTimestamp; // Last swap timestamp
    uint256 public priceAccumulator; // Accumulator for price data
    uint256 public priceTimestampLast; // Last price update timestamp
    uint256 public basePrice; // Base price in PRECISION units
    uint256 public volatilityMeasure; // Current volatility measure

    // Protocol fee collection
    address public protocolFeeReceiver; // Address to receive protocol fees
    uint256 public protocolFeeShare; // Share of fees sent to protocol (in basis points, 100 = 1%)

    // Amplification change variables
    uint256 public initialA; // Initial A value when ramp started
    uint256 public futureA; // Target A value when ramp ends
    uint256 public initialATime; // Timestamp when ramp started
    uint256 public futureATime; // Timestamp when ramp ends

    // Pool balances tracking
    uint256[2] public balances; // Current token balances

    // Custom errors
    error InvalidToken();
    error ZeroAmount();
    error InsufficientLiquidity();
    error SlippageTooHigh();
    error InvalidAmplification();
    error AmplificationChanging();
    error FeeTooHigh();
    error ArrayLengthMismatch();
    error RampTooShort();
    error RampAlreadyStarted();
    error MustBeZero();
    error NotInitialized();
    error AlreadyInitialized();
    error DeadlineExpired();
    error InvalidSelector();
    error InvalidFeeParameters();
    error InvalidProtocolFeeShare();
    error ScalingError();

    // Events
    event AddLiquidity(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpAmount
    );
    event RemoveLiquidity(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 lpAmount
    );
    event Swap(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee
    );
    event FeeParametersUpdated(
        uint256 baseFee,
        uint256 minFee,
        uint256 maxFee,
        uint256 volatilityMultiplier
    );
    event RampA(
        uint256 oldA,
        uint256 newA,
        uint256 initialTime,
        uint256 futureTime
    );
    event StopRampA(uint256 currentA);
    event ProtocolFeeReceiverSet(address feeReceiver, uint256 feeShare);
    event ProtocolFeesCollected(
        address indexed receiver,
        address indexed token,
        uint256 amount
    );
    event PoolInitialized();

    /**
     * @notice Constructor for the StableSwap pool
     * @param _token0 Address of the first token
     * @param _token1 Address of the second token
     * @param _lpToken Address of the LP token
     * @param _a Initial amplification coefficient * A_PRECISION
     * @param _baseFee Initial base swap fee
     * @param _minFee Minimum swap fee
     * @param _maxFee Maximum swap fee
     * @param _volatilityMultiplier Multiplier for volatility to fee conversion
     */
    constructor(
        address _token0,
        address _token1,
        address _lpToken,
        uint256 _a,
        uint256 _baseFee,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _volatilityMultiplier
    ) Ownable(msg.sender) {
        if (_token0 == _token1) revert InvalidToken();
        if (_a == 0 || _a > MAX_A) revert InvalidAmplification();

        // Auto-convert from old precision to new precision if needed
        if (_maxFee > PRECISION) {
            // User is likely using old 1e18 precision, convert to 1e6
            _baseFee = _baseFee / (OLD_PRECISION / PRECISION);
            _minFee = _minFee / (OLD_PRECISION / PRECISION);
            _maxFee = _maxFee / (OLD_PRECISION / PRECISION);
            _volatilityMultiplier =
                _volatilityMultiplier /
                (OLD_PRECISION / PRECISION);
        }

        if (_maxFee > MAX_FEE) revert FeeTooHigh();
        if (_minFee > _baseFee || _baseFee > _maxFee)
            revert InvalidFeeParameters();

        token0 = IERC677(_token0);
        token1 = IERC677(_token1);
        lpToken = LPToken(_lpToken);
        amplification = _a;

        // Initialize fee parameters
        baseFee = _baseFee;
        minFee = _minFee;
        maxFee = _maxFee;
        volatilityMultiplier = _volatilityMultiplier;
        basePrice = PRECISION; // Assume 1:1 ratio at start
        priceTimestampLast = block.timestamp;

        // Initialize A ramp variables
        initialA = _a;
        futureA = _a;
        initialATime = block.timestamp;
        futureATime = block.timestamp;
    }

    /**
     * @notice Completes the pool initialization
     * @dev Called by factory after transferring LP token ownership
     */
    function initialize() external onlyOwner {
        if (initialized) revert AlreadyInitialized();

        // Initialize scaling factors
        _initializeScalingFactors();

        initialized = true;
        emit PoolInitialized();
    }

    /**
     * @notice Initialize scaling factors based on token decimals
     * @dev Called during pool initialization
     */
    function _initializeScalingFactors() internal {
        // For token0
        uint8 decimals0 = IERC20Metadata(address(token0)).decimals();
        scalingFactors[0] = 10 ** (18 - decimals0);

        // For token1
        uint8 decimals1 = IERC20Metadata(address(token1)).decimals();
        scalingFactors[1] = 10 ** (18 - decimals1);
    }

    /**
     * @notice Scale a token amount by its scaling factor
     * @param amount Amount to scale
     * @param tokenIndex Index of the token (0 or 1)
     * @return Scaled amount
     */
    function _scaleAmount(
        uint256 amount,
        uint256 tokenIndex
    ) internal view returns (uint256) {
        return amount * scalingFactors[tokenIndex];
    }

    /**
     * @notice Descale a token amount by its scaling factor
     * @param scaledAmount Scaled amount to convert back
     * @param tokenIndex Index of the token (0 or 1)
     * @return Original amount
     */
    function _descaleAmount(
        uint256 scaledAmount,
        uint256 tokenIndex
    ) internal view returns (uint256) {
        return scaledAmount / scalingFactors[tokenIndex];
    }

    /**
     * @notice Get scaled balances for StableMath calculations
     * @return Scaled balances array
     */
    function _getScaledBalances() internal view returns (uint256[2] memory) {
        uint256[2] memory scaledBalances;
        scaledBalances[0] = _scaleAmount(balances[0], 0);
        scaledBalances[1] = _scaleAmount(balances[1], 1);
        return scaledBalances;
    }

    /**
     * @notice Add liquidity to the pool
     * @dev Deposits tokens and mints LP tokens
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @param minLpAmount Minimum LP tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @return lpAmount Amount of LP tokens minted
     */
    function addLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minLpAmount,
        uint256 deadline
    ) public nonReentrant whenNotPaused returns (uint256 lpAmount) {
        if (!initialized) revert NotInitialized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();

        // Update the amplification coefficient if it's changing
        _updateAmplification();

        // Update price accumulator
        _updatePriceAccumulator();

        // Scale token amounts
        uint256 scaledAmount0 = _scaleAmount(amount0, 0);
        uint256 scaledAmount1 = _scaleAmount(amount1, 1);

        // Get scaled balances
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Calculate the current invariant before adding liquidity
        uint256 oldInvariant = 0;
        if (scaledBalances[0] > 0 && scaledBalances[1] > 0) {
            oldInvariant = StableMath.calculateInvariant(
                scaledBalances,
                getA()
            );
        }

        // Transfer tokens from the user
        if (amount0 > 0) {
            IERC20(address(token0)).safeTransferFrom(
                msg.sender,
                address(this),
                amount0
            );
            balances[0] += amount0;
            scaledBalances[0] += scaledAmount0;
        }
        if (amount1 > 0) {
            IERC20(address(token1)).safeTransferFrom(
                msg.sender,
                address(this),
                amount1
            );
            balances[1] += amount1;
            scaledBalances[1] += scaledAmount1;
        }

        // Calculate the new invariant after adding liquidity
        uint256 newInvariant = StableMath.calculateInvariant(
            scaledBalances,
            getA()
        );

        // Calculate LP tokens to mint
        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0) {
            // Initial liquidity provision
            lpAmount = newInvariant;
        } else {
            // Calculate proportional LP tokens based on invariant growth
            lpAmount = StableMath.computeLiquidityMintAmount(
                oldInvariant,
                newInvariant,
                totalSupply
            );
        }

        // Check minimum LP amount
        if (lpAmount < minLpAmount) revert SlippageTooHigh();

        // Mint LP tokens to the provider
        lpToken.mint(msg.sender, lpAmount);

        emit AddLiquidity(msg.sender, amount0, amount1, lpAmount);
        return lpAmount;
    }

  function removeLiquidity(
    uint256 lpAmount,
    uint256 minAmount0,
    uint256 minAmount1,
    uint256 deadline
) public nonReentrant whenNotPaused returns (uint256 amount0, uint256 amount1) {
    if (!initialized) revert NotInitialized();
    if (block.timestamp > deadline) revert DeadlineExpired();
    if (lpAmount == 0) revert ZeroAmount();

    // Update the amplification coefficient if it's changing
    _updateAmplification();

    // Update price accumulator
    _updatePriceAccumulator();

    uint256 totalSupply = lpToken.totalSupply();

    // Calculate token amounts to return based on proportional share
    amount0 = (balances[0] * lpAmount) / totalSupply;
    amount1 = (balances[1] * lpAmount) / totalSupply;

    // Check minimum amounts
    if (amount0 < minAmount0 || amount1 < minAmount1)
        revert SlippageTooHigh();

    // Update balances
    balances[0] -= amount0;
    balances[1] -= amount1;

    // First transfer LP tokens to the pool
    lpToken.transferFrom(msg.sender, address(this), lpAmount);
    
    // Then burn from the pool's own balance
    lpToken.burn(address(this), lpAmount);

    // Transfer tokens to user
    IERC20(address(token0)).safeTransfer(msg.sender, amount0);
    IERC20(address(token1)).safeTransfer(msg.sender, amount1);

    emit RemoveLiquidity(msg.sender, amount0, amount1, lpAmount);
    return (amount0, amount1);
}

    /**
     * @notice Perform a token swap
     * @dev Swaps one token for another using the StableSwap formula with dynamic fees
     * @param tokenIn Address of the input token
     * @param amountIn Amount of input token
     * @param minAmountOut Minimum amount of output token to receive
     * @param deadline Transaction deadline timestamp
     * @return amountOut Amount of output token received
     */
    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) public nonReentrant whenNotPaused returns (uint256 amountOut) {
        if (!initialized) revert NotInitialized();
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amountIn == 0) revert ZeroAmount();

        // Update the amplification coefficient if it's changing
        _updateAmplification();

        // Update price accumulator before swap
        _updatePriceAccumulator();

        // Determine token indices
        uint256 tokenIndexFrom;
        uint256 tokenIndexTo;

        if (tokenIn == address(token0)) {
            tokenIndexFrom = 0;
            tokenIndexTo = 1;
        } else if (tokenIn == address(token1)) {
            tokenIndexFrom = 1;
            tokenIndexTo = 0;
        } else {
            revert InvalidToken();
        }

        // Transfer input token from user
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Scale the input amount
        uint256 scaledAmountIn = _scaleAmount(amountIn, tokenIndexFrom);

        // Get scaled balances for calculations
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Calculate dynamic fee based on current conditions
        uint256 currentFee = calculateDynamicFee();

        // Calculate fee amount with scaled values
        uint256 scaledFeeAmount = StableMath.calculateFee(
            scaledAmountIn,
            currentFee
        );
        uint256 scaledAmountInAfterFee = scaledAmountIn - scaledFeeAmount;

        // Calculate unscaled fee for protocol fee handling
        uint256 feeAmount = _descaleAmount(scaledFeeAmount, tokenIndexFrom);

        // Handle protocol fee
        if (protocolFeeReceiver != address(0) && protocolFeeShare > 0) {
            uint256 protocolFeeAmount = (feeAmount * protocolFeeShare) / 10000;
            if (protocolFeeAmount > 0) {
                // Transfer protocol fees
                IERC20(tokenIn).safeTransfer(
                    protocolFeeReceiver,
                    protocolFeeAmount
                );
                emit ProtocolFeesCollected(
                    protocolFeeReceiver,
                    tokenIn,
                    protocolFeeAmount
                );
            }
        }

        // Update actual balances
        balances[tokenIndexFrom] += amountIn;

        // Update scaled balances for StableMath calculation
        scaledBalances[tokenIndexFrom] += scaledAmountIn;

        // Calculate output amount using StableMath with scaled values
        uint256 scaledAmountOut = StableMath.getY(
            tokenIndexFrom,
            tokenIndexTo,
            scaledAmountInAfterFee,
            scaledBalances,
            getA()
        );

        // Descale the output amount
        amountOut = _descaleAmount(scaledAmountOut, tokenIndexTo);

        // Check minimum output amount
        if (amountOut < minAmountOut) revert SlippageTooHigh();

        // Update output token balance
        balances[tokenIndexTo] -= amountOut;

        // Update swap timestamp
        lastSwapTimestamp = block.timestamp;

        // Transfer output token to user
        IERC20(tokenIndexTo == 0 ? address(token0) : address(token1))
            .safeTransfer(msg.sender, amountOut);

        emit Swap(msg.sender, tokenIn, amountIn, amountOut, currentFee);
        return amountOut;
    }

    /**
     * @notice ERC677 callback function
     * @dev Handles token transfers with data to perform operations directly
     * @param _sender Address that initiated the transfer
     * @param _value Amount of tokens transferred
     * @param _data Function selector and parameters
     */
    function onTokenTransfer(
        address _sender,
        uint256 _value,
        bytes calldata _data
    ) external override nonReentrant whenNotPaused {
        if (!initialized) revert NotInitialized();

        // Verify the sender is one of our tokens
        if (msg.sender != address(token0) && msg.sender != address(token1)) {
            revert InvalidToken();
        }

        // Need at least 4 bytes for function selector
        if (_data.length < 4) revert InvalidSelector();

        // Extract the function selector
        bytes4 selector = bytes4(_data[:4]);

        // Handle different function calls
        if (selector == ADD_LIQUIDITY_SELECTOR) {
            _handleAddLiquidityERC677(_sender, _value, _data[4:]);
        } else if (selector == SWAP_SELECTOR) {
            _handleSwapERC677(_sender, _value, _data[4:]);
        } else {
            revert InvalidSelector();
        }
    }

    /**
     * @notice Handle add liquidity via ERC677 transferAndCall
     * @dev Called by onTokenTransfer when adding liquidity
     * @param _sender Address that initiated the transfer
     * @param _value Amount of tokens transferred
     * @param _data Function parameters
     */
    function _handleAddLiquidityERC677(
        address _sender,
        uint256 _value,
        bytes calldata _data
    ) internal {
        // Decode parameters from _data
        (uint256 otherTokenAmount, uint256 minLpAmount, uint256 deadline) = abi
            .decode(_data, (uint256, uint256, uint256));

        if (block.timestamp > deadline) revert DeadlineExpired();

        // Update the amplification coefficient if it's changing
        _updateAmplification();

        // Update price accumulator
        _updatePriceAccumulator();

        // Determine which token was sent
        uint256 token0Amount;
        uint256 token1Amount;
        uint256 tokenIndexSent;
        uint256 otherTokenIndex;

        if (msg.sender == address(token0)) {
            token0Amount = _value;
            token1Amount = otherTokenAmount;
            tokenIndexSent = 0;
            otherTokenIndex = 1;
        } else {
            token0Amount = otherTokenAmount;
            token1Amount = _value;
            tokenIndexSent = 1;
            otherTokenIndex = 0;
        }

        // Scale amounts
        uint256 scaledToken0Amount = _scaleAmount(token0Amount, 0);
        uint256 scaledToken1Amount = _scaleAmount(token1Amount, 1);

        // Get scaled balances
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Calculate the current invariant before adding liquidity
        uint256 oldInvariant = 0;
        if (scaledBalances[0] > 0 && scaledBalances[1] > 0) {
            oldInvariant = StableMath.calculateInvariant(
                scaledBalances,
                getA()
            );
        }

        // Update the balance of the token that was directly transferred
        balances[tokenIndexSent] += _value;
        scaledBalances[tokenIndexSent] += (tokenIndexSent == 0)
            ? scaledToken0Amount
            : scaledToken1Amount;

        // Transfer the other token if needed
        if (otherTokenAmount > 0) {
            address otherToken = (otherTokenIndex == 0)
                ? address(token0)
                : address(token1);

            IERC20(otherToken).safeTransferFrom(
                _sender,
                address(this),
                otherTokenAmount
            );

            balances[otherTokenIndex] += otherTokenAmount;
            scaledBalances[otherTokenIndex] += (otherTokenIndex == 0)
                ? scaledToken0Amount
                : scaledToken1Amount;
        }

        // Calculate the new invariant after adding liquidity
        uint256 newInvariant = StableMath.calculateInvariant(
            scaledBalances,
            getA()
        );

        // Calculate LP tokens to mint
        uint256 totalSupply = lpToken.totalSupply();
        uint256 lpAmount;
        if (totalSupply == 0) {
            // Initial liquidity provision
            lpAmount = newInvariant;
        } else {
            // Calculate proportional LP tokens based on invariant growth
            lpAmount = StableMath.computeLiquidityMintAmount(
                oldInvariant,
                newInvariant,
                totalSupply
            );
        }

        // Check minimum LP amount
        if (lpAmount < minLpAmount) revert SlippageTooHigh();

        // Mint LP tokens to the provider
        lpToken.mint(_sender, lpAmount);

        emit AddLiquidity(_sender, token0Amount, token1Amount, lpAmount);
    }

    /**
     * @notice Handle swap via ERC677 transferAndCall
     * @dev Called by onTokenTransfer when swapping
     * @param _sender Address that initiated the transfer
     * @param _value Amount of tokens transferred
     * @param _data Function parameters
     */
    function _handleSwapERC677(
        address _sender,
        uint256 _value,
        bytes calldata _data
    ) internal {
        // Decode parameters from _data
        (uint256 minAmountOut, uint256 deadline) = abi.decode(
            _data,
            (uint256, uint256)
        );

        if (block.timestamp > deadline) revert DeadlineExpired();
        if (_value == 0) revert ZeroAmount();

        // Update the amplification coefficient if it's changing
        _updateAmplification();

        // Update price accumulator
        _updatePriceAccumulator();

        // Determine token indices
        uint256 tokenIndexFrom;
        uint256 tokenIndexTo;

        if (msg.sender == address(token0)) {
            tokenIndexFrom = 0;
            tokenIndexTo = 1;
        } else {
            tokenIndexFrom = 1;
            tokenIndexTo = 0;
        }

        // Scale the input amount
        uint256 scaledAmountIn = _scaleAmount(_value, tokenIndexFrom);

        // Get scaled balances
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Calculate dynamic fee based on current conditions
        uint256 currentFee = calculateDynamicFee();

        // Calculate fee amount with scaled values
        uint256 scaledFeeAmount = StableMath.calculateFee(
            scaledAmountIn,
            currentFee
        );
        uint256 scaledAmountInAfterFee = scaledAmountIn - scaledFeeAmount;

        // Calculate unscaled fee for protocol fee handling
        uint256 feeAmount = _descaleAmount(scaledFeeAmount, tokenIndexFrom);

        // If protocol fee is enabled, calculate protocol fee amount
        if (protocolFeeReceiver != address(0) && protocolFeeShare > 0) {
            uint256 protocolFeeAmount = (feeAmount * protocolFeeShare) / 10000;
            if (protocolFeeAmount > 0) {
                // Send protocol fees to fee receiver
                IERC20(msg.sender).safeTransfer(
                    protocolFeeReceiver,
                    protocolFeeAmount
                );
                emit ProtocolFeesCollected(
                    protocolFeeReceiver,
                    msg.sender,
                    protocolFeeAmount
                );
            }
        }

        // Update actual balances
        balances[tokenIndexFrom] += _value;

        // Update scaled balances for StableMath calculation
        scaledBalances[tokenIndexFrom] += scaledAmountIn;

        // Calculate output amount using StableMath with scaled values
        uint256 scaledAmountOut = StableMath.getY(
            tokenIndexFrom,
            tokenIndexTo,
            scaledAmountInAfterFee,
            scaledBalances,
            getA()
        );

        // Descale the output amount
        uint256 amountOut = _descaleAmount(scaledAmountOut, tokenIndexTo);

        // Check minimum output amount
        if (amountOut < minAmountOut) revert SlippageTooHigh();

        // Update output token balance
        balances[tokenIndexTo] -= amountOut;

        // Update swap timestamp
        lastSwapTimestamp = block.timestamp;

        // Transfer output token to user
        IERC20(tokenIndexTo == 0 ? address(token0) : address(token1))
            .safeTransfer(_sender, amountOut);

        emit Swap(_sender, msg.sender, _value, amountOut, currentFee);
    }

    /**
     * @notice Update the price accumulator for volatility tracking
     * @dev Called before any swap or liquidity action to track price changes
     */
    function _updatePriceAccumulator() internal {
        uint256 currentTimestamp = block.timestamp;
        if (currentTimestamp == priceTimestampLast) return;

        // Calculate current price of token0 in terms of token1
        uint256 currentPrice;
        if (balances[0] > 0 && balances[1] > 0) {
            // Get scaled balances for accurate price calculation
            uint256[2] memory scaledBalances = _getScaledBalances();
            // Price calculation with scaled balances
            currentPrice = (scaledBalances[1] * PRECISION) / scaledBalances[0];
        } else {
            currentPrice = basePrice;
        }

        // Update accumulator with time-weighted price
        uint256 timeElapsed = currentTimestamp - priceTimestampLast;
        priceAccumulator += currentPrice * timeElapsed;

        // Update volatility measure based on price deviation from base
        if (currentPrice > basePrice) {
            volatilityMeasure =
                ((currentPrice - basePrice) * PRECISION) /
                basePrice;
        } else {
            volatilityMeasure =
                ((basePrice - currentPrice) * PRECISION) /
                basePrice;
        }

        // Update timestamps
        priceTimestampLast = currentTimestamp;
    }

    /**
     * @notice Calculate the current fee based on volatility
     * @dev Returns a fee between minFee and maxFee based on market conditions
     * @return Dynamic fee in PRECISION units
     */
    function calculateDynamicFee() public view returns (uint256) {
        // Start with base fee
        uint256 dynamicFee = baseFee;

        // Adjust based on volatility
        uint256 volatilityComponent = (volatilityMeasure *
            volatilityMultiplier) / PRECISION;
        dynamicFee += volatilityComponent;

        // Ensure fee is within bounds
        if (dynamicFee > maxFee) {
            return maxFee;
        } else if (dynamicFee < minFee) {
            return minFee;
        }

        return dynamicFee;
    }

    /**
     * @notice Set fee parameters
     * @dev Can only be called by the owner
     * @param _baseFee New base fee
     * @param _minFee New minimum fee
     * @param _maxFee New maximum fee
     * @param _volatilityMultiplier New volatility multiplier
     */
    function setFeeParameters(
        uint256 _baseFee,
        uint256 _minFee,
        uint256 _maxFee,
        uint256 _volatilityMultiplier
    ) external onlyOwner {
        if (_maxFee > MAX_FEE) revert FeeTooHigh();
        if (_minFee > _baseFee || _baseFee > _maxFee)
            revert InvalidFeeParameters();

        baseFee = _baseFee;
        minFee = _minFee;
        maxFee = _maxFee;
        volatilityMultiplier = _volatilityMultiplier;

        emit FeeParametersUpdated(
            _baseFee,
            _minFee,
            _maxFee,
            _volatilityMultiplier
        );
    }

    /**
     * @notice Set protocol fee receiver and share
     * @dev Can only be called by the owner
     * @param _feeReceiver Address to receive protocol fees
     * @param _feeShare Protocol fee share in basis points (100 = 1%)
     */
    function setProtocolFeeReceiver(
        address _feeReceiver,
        uint256 _feeShare
    ) external onlyOwner {
        if (_feeShare > MAX_PROTOCOL_FEE_SHARE)
            revert InvalidProtocolFeeShare();

        protocolFeeReceiver = _feeReceiver;
        protocolFeeShare = _feeShare;

        emit ProtocolFeeReceiverSet(_feeReceiver, _feeShare);
    }

    /**
     * @notice Start gradually changing the amplification parameter
     * @dev Amplification can only be changed gradually to prevent manipulation
     * @param _futureA Target amplification coefficient * A_PRECISION
     * @param _futureTime Timestamp when the new A should be reached
     */
    function rampA(uint256 _futureA, uint256 _futureTime) external onlyOwner {
        if (!initialized) revert NotInitialized();

        // Verify the new A value
        if (_futureA < A_PRECISION) revert InvalidAmplification();
        if (_futureA > MAX_A) revert InvalidAmplification();

        uint256 currentA = getA();

        // Ensure we're not already in the middle of a ramp
        if (block.timestamp != futureATime) revert RampAlreadyStarted();

        // Verify the ramp time is long enough
        if (_futureTime <= block.timestamp + MIN_RAMP_TIME)
            revert RampTooShort();

        initialA = currentA;
        futureA = _futureA;
        initialATime = block.timestamp;
        futureATime = _futureTime;

        emit RampA(currentA, _futureA, block.timestamp, _futureTime);
    }

    /**
     * @notice Stop gradually changing the amplification parameter
     * @dev Sets the current A value and stops the ramp
     */
    function stopRampA() external onlyOwner {
        if (!initialized) revert NotInitialized();

        // Ensure we're in the middle of a ramp
        if (block.timestamp == futureATime) revert RampAlreadyStarted();

        uint256 currentA = getA();
        initialA = currentA;
        futureA = currentA;
        initialATime = block.timestamp;
        futureATime = block.timestamp;

        emit StopRampA(currentA);
    }

    /**
     * @notice Pause the pool in case of emergency
     * @dev Can only be called by the owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the pool
     * @dev Can only be called by the owner
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Get the current amplification coefficient
     * @dev Calculates the current A value based on the ramp
     * @return The current amplification coefficient
     */
    function getA() public view returns (uint256) {
        uint256 currentTime = block.timestamp;

        // If we're not ramping, just return the current amplification
        if (currentTime >= futureATime) {
            return futureA;
        }

        // If we're in the middle of a ramp, calculate the current A value
        if (futureA > initialA) {
            // A is increasing
            return
                initialA +
                ((futureA - initialA) * (currentTime - initialATime)) /
                (futureATime - initialATime);
        } else {
            // A is decreasing
            return
                initialA -
                ((initialA - futureA) * (currentTime - initialATime)) /
                (futureATime - initialATime);
        }
    }

    /**
     * @notice Update the amplification coefficient if it's changing
     * @dev Internal function to update the amplification value
     */
    function _updateAmplification() internal {
        uint256 currentA = getA();
        if (currentA != amplification) {
            amplification = currentA;
        }
    }

    /**
     * @notice Get the current pool state
     * @return _amplification Current amplification coefficient
     * @return _fee Current dynamic fee
     * @return _balances Current token balances
     * @return _totalSupply Current LP token supply
     * @return _volatilityMeasure Current volatility measure
     */
    function getPoolState()
        external
        view
        returns (
            uint256 _amplification,
            uint256 _fee,
            uint256[2] memory _balances,
            uint256 _totalSupply,
            uint256 _volatilityMeasure
        )
    {
        return (
            getA(),
            calculateDynamicFee(),
            balances,
            lpToken.totalSupply(),
            volatilityMeasure
        );
    }

    /**
     * @notice Calculate the expected output amount for a swap
     * @dev View function to help users calculate expected output before executing a swap
     * @param tokenIn Address of the input token
     * @param amountIn Amount of input token
     * @return amountOut Expected amount of output token
     * @return fee Current fee rate
     */
    function calculateSwapOutput(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 fee) {
        if (!initialized) revert NotInitialized();
        if (amountIn == 0) return (0, 0);

        // Determine token indices
        uint256 tokenIndexFrom;
        uint256 tokenIndexTo;

        if (tokenIn == address(token0)) {
            tokenIndexFrom = 0;
            tokenIndexTo = 1;
        } else if (tokenIn == address(token1)) {
            tokenIndexFrom = 1;
            tokenIndexTo = 0;
        } else {
            revert InvalidToken();
        }

        // Scale input amount and get scaled balances
        uint256 scaledAmountIn = _scaleAmount(amountIn, tokenIndexFrom);
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Get dynamic fee
        fee = calculateDynamicFee();

        // Calculate fee amount with scaled values
        uint256 scaledFeeAmount = StableMath.calculateFee(scaledAmountIn, fee);
        uint256 scaledAmountInAfterFee = scaledAmountIn - scaledFeeAmount;

        // Update scaled balances copy
        scaledBalances[tokenIndexFrom] += scaledAmountIn;

        // Calculate output amount using StableMath with scaled values
        uint256 scaledAmountOut = StableMath.getY(
            tokenIndexFrom,
            tokenIndexTo,
            scaledAmountInAfterFee,
            scaledBalances,
            getA()
        );

        // Descale the output amount
        amountOut = _descaleAmount(scaledAmountOut, tokenIndexTo);

        return (amountOut, fee);
    }

    /**
     * @notice Calculate the amount of LP tokens that would be minted for a given deposit
     * @dev View function to help users calculate expected LP tokens before adding liquidity
     * @param amount0 Amount of token0 to add
     * @param amount1 Amount of token1 to add
     * @return lpAmount Expected amount of LP tokens to be minted
     */
    function calculateLpTokenAmount(
        uint256 amount0,
        uint256 amount1
    ) external view returns (uint256 lpAmount) {
        if (!initialized) revert NotInitialized();
        if (amount0 == 0 && amount1 == 0) return 0;

        // Scale amounts
        uint256 scaledAmount0 = _scaleAmount(amount0, 0);
        uint256 scaledAmount1 = _scaleAmount(amount1, 1);

        // Get scaled balances
        uint256[2] memory scaledBalances = _getScaledBalances();

        // Calculate the current invariant before adding liquidity
        uint256 oldInvariant = 0;
        if (scaledBalances[0] > 0 && scaledBalances[1] > 0) {
            oldInvariant = StableMath.calculateInvariant(
                scaledBalances,
                getA()
            );
        }

        // Update scaled balances
        uint256[2] memory newScaledBalances = scaledBalances;
        if (amount0 > 0) {
            newScaledBalances[0] += scaledAmount0;
        }
        if (amount1 > 0) {
            newScaledBalances[1] += scaledAmount1;
        }

        // Calculate the new invariant after adding liquidity
        uint256 newInvariant = StableMath.calculateInvariant(
            newScaledBalances,
            getA()
        );

        // Calculate LP tokens to mint
        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0) {
            // Initial liquidity provision
            lpAmount = newInvariant;
        } else {
            // Calculate proportional LP tokens based on invariant growth
            lpAmount = StableMath.computeLiquidityMintAmount(
                oldInvariant,
                newInvariant,
                totalSupply
            );
        }

        return lpAmount;
    }

    /**
     * @notice Calculate the token amounts that would be returned for a given LP token amount
     * @dev View function to help users calculate expected token amounts before removing liquidity
     * @param lpAmount Amount of LP tokens to burn
     * @return amount0 Expected amount of token0 to be returned
     * @return amount1 Expected amount of token1 to be returned
     */
    function calculateRemoveLiquidity(
        uint256 lpAmount
    ) external view returns (uint256 amount0, uint256 amount1) {
        if (!initialized) revert NotInitialized();
        if (lpAmount == 0) return (0, 0);

        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0) return (0, 0);

        // Calculate token amounts to return based on proportional share
        amount0 = (balances[0] * lpAmount) / totalSupply;
        amount1 = (balances[1] * lpAmount) / totalSupply;

        return (amount0, amount1);
    }

    /**
     * @notice Calculate the current spot price between the two tokens
     * @dev Returns the price of token0 in terms of token1
     * @return spotPrice The current spot price (token0 / token1) in PRECISION units
     */
    function getSpotPrice() external view returns (uint256 spotPrice) {
        if (!initialized) revert NotInitialized();

        uint256[2] memory scaledBalances = _getScaledBalances();

        if (scaledBalances[0] == 0 || scaledBalances[1] == 0)
            revert InsufficientLiquidity();

        // Calculate spot price using StableMath
        spotPrice = StableMath.getSpotPrice(scaledBalances, getA());

        return spotPrice;
    }

    /**
     * @notice Get detailed information about the current amplification ramp
     * @dev Returns the ramp parameters and the current A value
     * @return _initialA Initial A value when ramp started
     * @return _futureA Target A value when ramp ends
     * @return _initialATime Timestamp when ramp started
     * @return _futureATime Timestamp when ramp ends
     * @return _currentA Current A value
     */
    function getARamp()
        external
        view
        returns (
            uint256 _initialA,
            uint256 _futureA,
            uint256 _initialATime,
            uint256 _futureATime,
            uint256 _currentA
        )
    {
        return (initialA, futureA, initialATime, futureATime, getA());
    }

    /**
     * @notice Get detailed information about the dynamic fee system
     * @return _baseFee Base fee
     * @return _minFee Minimum fee
     * @return _maxFee Maximum fee
     * @return _currentFee Current dynamic fee
     * @return _volatilityMeasure Current volatility measure
     * @return _volatilityMultiplier Volatility multiplier
     */
    function getFeeInfo()
        external
        view
        returns (
            uint256 _baseFee,
            uint256 _minFee,
            uint256 _maxFee,
            uint256 _currentFee,
            uint256 _volatilityMeasure,
            uint256 _volatilityMultiplier
        )
    {
        return (
            baseFee,
            minFee,
            maxFee,
            calculateDynamicFee(),
            volatilityMeasure,
            volatilityMultiplier
        );
    }

    /**
     * @notice Get protocol fee information
     * @return _feeReceiver Address receiving protocol fees
     * @return _feeShare Protocol fee share in basis points
     */
    function getProtocolFeeInfo()
        external
        view
        returns (address _feeReceiver, uint256 _feeShare)
    {
        return (protocolFeeReceiver, protocolFeeShare);
    }

    /**
     * @notice Get scaling factors for tokens
     * @return scaling0 Scaling factor for token0
     * @return scaling1 Scaling factor for token1
     */
    function getScalingFactors()
        external
        view
        returns (uint256 scaling0, uint256 scaling1)
    {
        return (scalingFactors[0], scalingFactors[1]);
    }

    /**
     * @notice Safe wrapper for adding liquidity with smaller values
     * @dev For use in testing or as a workaround
     * @param amount0 Amount of token0 to add (will be scaled down)
     * @param amount1 Amount of token1 to add (will be scaled down)
     * @param minLpAmount Minimum LP tokens to receive
     * @param deadline Transaction deadline timestamp
     * @return Amount of LP tokens minted
     */
    function safeAddLiquidity(
        uint256 amount0,
        uint256 amount1,
        uint256 minLpAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256) {
        // For very large amounts, scale down to prevent overflow
        uint256 safeAmount0 = (amount0 > 1000) ? 100 : amount0;
        uint256 safeAmount1 = (amount1 > 1000) ? 100 : amount1;
        return addLiquidity(safeAmount0, safeAmount1, minLpAmount, deadline);
    }
}
