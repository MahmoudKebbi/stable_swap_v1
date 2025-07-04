// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title StableMath
 * @notice Math library for StableSwap operations with overflow protection
 * and support for tokens with different decimal places.
 */
library StableMath {
    // ================ Constants ================

    // Use lower precision to prevent overflow
    uint256 internal constant A_PRECISION = 100;

    // Maximum allowed amplification coefficient (reduced from previous value)
    uint256 internal constant MAX_A = 10000;

    // Maximum allowed number of iterations for convergence
    uint256 internal constant MAX_ITERATIONS = 32;

    // Precision for fixed-point calculations (reduced from 1e18)
    uint256 internal constant PRECISION = 1e6;

    // ================ Custom Errors ================

    error InvalidAmplification();
    error SameTokenIndices();
    error InvalidTokenIndex();
    error OutputExceedsBalance();
    error DidNotConverge();

    // ================ Core Math Functions ================

    /**
     * @notice Safe multiplication to prevent overflow
     */
    function mulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / PRECISION;
    }

    /**
     * @notice Safe division with rounding down
     */
    function divDown(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;
        return (a * PRECISION) / b;
    }

    /**
     * @notice Safe division with rounding up
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) return 0;

        // Equivalent to ceil(a * PRECISION / b)
        return (a * PRECISION + b - 1) / b;
    }

    /**
     * @notice Calculate the StableSwap invariant (D)
     * @param balances Array of token balances (already scaled by their respective factors)
     * @param amplification Amplification coefficient (A) - scaled by A_PRECISION
     * @return D The invariant value
     */
    function calculateInvariant(
        uint256[2] memory balances,
        uint256 amplification
    ) public pure returns (uint256 D) {
        // Verify amplification is within limits
        if (amplification == 0 || amplification > MAX_A)
            revert InvalidAmplification();

        uint256 sum = balances[0] + balances[1];
        if (sum == 0) return 0;

        // Initial guess for D: sum of balances
        uint256 D_prev;
        D = sum;

        // Amplification coefficient A in the StableSwap formula
        // Ann = A * n^(n-1) = A * 2 for n=2
        uint256 Ann = amplification * 2;

        for (uint256 i = 0; i < MAX_ITERATIONS; ) {
            // Break down calculations to prevent overflow

            // Calculate D_P = D^3 / (x_0 * x_1 * 4)
            uint256 D_P;

            if (balances[0] > 0 && balances[1] > 0) {
                // Calculate step by step with safe operations
                uint256 balancesProduct = balances[0] * balances[1];
                if (balancesProduct > 0) {
                    uint256 d_squared = D * D; // Changed from 'numerator' to 'd_squared'
                    D_P = ((d_squared / balancesProduct) * D) / 4;
                } else {
                    D_P = 0;
                }
            } else {
                D_P = 0;
            }

            D_prev = D;

            // D = (Ann * sum + D_P * n) * D / ((Ann - 1) * D + (n + 1) * D_P)
            // For n=2, this simplifies to the calculation below

            // Calculate parts separately to avoid overflow
            uint256 numerator1 = Ann * sum;
            uint256 numerator2 = D_P * 2;
            uint256 numerator = (numerator1 + numerator2) * D;

            uint256 denominator1 = (Ann - 1) * D;
            uint256 denominator2 = 3 * D_P;
            uint256 denominator = denominator1 + denominator2;

            // Prevent division by zero
            if (denominator > 0) {
                D = numerator / denominator;
            } else {
                break; // Unable to calculate further
            }

            // Check if we've converged
            if (D > D_prev) {
                if (D - D_prev <= 1) {
                    break;
                }
            } else {
                if (D_prev - D <= 1) {
                    break;
                }
            }

            unchecked {
                ++i;
            }
        }

        return D;
    }

    /**
     * @notice Calculate the output amount (Y) when swapping
     * @param tokenIndexFrom Index of input token (0 or 1)
     * @param tokenIndexTo Index of output token (0 or 1)
     * @param amountIn Amount of input token (already scaled)
     * @param balances Current balances of both tokens (already scaled)
     * @param amplification Amplification coefficient
     * @return Amount of output token (scaled)
     */
    function getY(
        uint256 tokenIndexFrom,
        uint256 tokenIndexTo,
        uint256 amountIn,
        uint256[2] memory balances,
        uint256 amplification
    ) public pure returns (uint256) {
        if (tokenIndexFrom == tokenIndexTo) revert SameTokenIndices();
        if (tokenIndexFrom >= 2 || tokenIndexTo >= 2)
            revert InvalidTokenIndex();

        // Calculate the invariant D with current balances
        uint256 D = calculateInvariant(balances, amplification);

        // Update the balance of the input token
        uint256 newBalanceFrom = balances[tokenIndexFrom] + amountIn;
        uint256 Ann = amplification * 2;

        // Solve for the new balance of the output token that maintains the invariant

        // Calculate c = D^3 / (4 * A * x_0)
        uint256 c = 0;
        if (newBalanceFrom > 0 && Ann > 0) {
            // Calculate step by step to avoid overflow
            uint256 term1 = D * D;
            uint256 term2 = newBalanceFrom * Ann;
            if (term2 > 0) {
                c = ((term1 / term2) * D) / 2;
            }
        }

        // Then, solve for y (balance of output token)
        uint256 b = newBalanceFrom + D / Ann;
        uint256 yPrev;
        uint256 y = D;

        // Iteratively find y using Newton's method
        for (uint256 i = 0; i < MAX_ITERATIONS; ) {
            yPrev = y;

            // Formula: y = (y^2 + c) / (2 * y + b - D)
            if (y > 0) {
                uint256 y_squared = y * y;
                uint256 numerator = y_squared + c;
                uint256 denominator = 2 * y + b - D;

                if (denominator > 0) {
                    y = numerator / denominator;
                } else {
                    // If denominator would be negative, use a fallback
                    y = numerator / (2 * y + 1);
                }
            } else {
                // If y becomes zero, use a small value to continue
                y = 1;
            }

            // Check if we've converged
            if (i > 0) {
                // Skip first iteration check
                uint256 diff = (y > yPrev) ? (y - yPrev) : (yPrev - y);
                if (diff <= 1) {
                    break;
                }
            }

            unchecked {
                ++i;
            }
        }

        // Ensure the new y value is valid
        if (y > balances[tokenIndexTo]) revert OutputExceedsBalance();

        return balances[tokenIndexTo] - y;
    }

    /**
     * @notice Calculate LP tokens to mint when adding liquidity
     * @param oldInvariant Previous invariant value
     * @param newInvariant New invariant value after adding liquidity
     * @param totalSupply Current supply of LP tokens
     * @return Amount of LP tokens to mint
     */
    function computeLiquidityMintAmount(
        uint256 oldInvariant,
        uint256 newInvariant,
        uint256 totalSupply
    ) public pure returns (uint256) {
        if (totalSupply == 0) {
            return newInvariant; // Initial mint
        }

        // No mint if no growth
        if (newInvariant <= oldInvariant) return 0;

        // Calculate proportional share based on invariant growth
        return (totalSupply * (newInvariant - oldInvariant)) / oldInvariant;
    }

    /**
     * @notice Calculate fee amount
     * @param amount Amount being swapped
     * @param fee Fee rate in PRECISION precision (e.g., 0.04% = 4e4)
     * @return Fee amount
     */
    function calculateFee(
        uint256 amount,
        uint256 fee
    ) public pure returns (uint256) {
        return mulDown(amount, fee);
    }

    /**
     * @notice Calculates the spot price of the token pair
     * @param balances Current balances of both tokens (already scaled)
     * @param amplification Amplification coefficient
     * @return Spot price as a fixed-point number with PRECISION
     */
    function getSpotPrice(
        uint256[2] memory balances,
        uint256 amplification
    ) public pure returns (uint256) {
        if (balances[0] == 0 || balances[1] == 0) return 0;

        uint256 D = calculateInvariant(balances, amplification);
        uint256 Ann = amplification * 2;
        uint256 nA = Ann / A_PRECISION;

        // Safe calculations for spot price
        if (nA == 0 || D == 0) return 0;

        // For a 2-token pool, spot price = x/y * (1 + D/(4*A*x*y))

        // Calculate basic ratio: x/y
        uint256 baseRatio = divDown(balances[0], balances[1]);

        // Calculate amplification effect: D/(4*A*x*y)
        uint256 xy = balances[0] * balances[1];
        if (xy == 0) return baseRatio; // Prevent division by zero

        uint256 ampEffect = divDown(D, 4 * nA * xy);

        // Final price: x/y * (1 + D/(4*A*x*y))
        return mulDown(baseRatio, PRECISION + ampEffect);
    }

    /**
     * @notice Calculate the square root of a number
     * @dev Uses Babylonian method for square root approximation
     * @param x The number to calculate the square root of
     * @return y The square root of x
     */
    function sqrt(uint256 x) public pure returns (uint256 y) {
        if (x == 0) return 0;

        // Initial guess: x/2
        uint256 z = (x + 1) / 2;
        y = x;

        // Babylonian method for square root
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
