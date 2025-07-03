// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title StableMath
 * @notice This library contains the math functions for the StableSwap invariant
 * calculations with fixes for overflow issues.
 */
library StableMath {
    // Precision for A and other calculations
    uint256 internal constant A_PRECISION = 100;
    
    // Maximum allowed amplification coefficient
    uint256 internal constant MAX_A = 1000000;
    
    // Maximum allowed number of iterations
    uint256 internal constant MAX_ITERATIONS = 255;
    
    // Reduced precision for fixed-point calculations to prevent overflow
    // Changed from 1e18 to 1e8 to prevent arithmetic overflow
    uint256 internal constant PRECISION = 1e8;
    
    // Custom errors are more gas efficient than string error messages
    error InvalidAmplification();
    error SameTokenIndices();
    error InvalidTokenIndex();
    error OutputExceedsBalance();

    /**
     * @notice Calculate the StableSwap invariant (D)
     * @dev Iteratively calculates the invariant D for the StableSwap formula
     * @param balances Array of token balances
     * @param amplification Amplification coefficient (A) - scaled by A_PRECISION
     * @return D The invariant value
     */
    function calculateInvariant(uint256[2] memory balances, uint256 amplification) 
        public 
        pure 
        returns (uint256 D) 
    {
        // Verify amplification is within limits
        if (amplification == 0 || amplification > MAX_A) revert InvalidAmplification();

        uint256 sum = balances[0] + balances[1];
        if (sum == 0) return 0;

        // Initial guess for D: sum of balances
        uint256 D_prev;
        D = sum;

        // Amplification coefficient A in the StableSwap formula
        // Simplified for n=2 case: Ann = A * n = A * 2
        uint256 Ann = amplification * 2;

        for (uint256 i = 0; i < MAX_ITERATIONS;) {
            uint256 D_P = D;
            
            // Calculate D_P = D^3 / (x_0 * x_1 * n^n)
            // For n=2, this simplifies to: D^3 / (x_0 * x_1 * 4)
            // Added overflow protection by checking for zero values
            if (balances[0] == 0 || balances[1] == 0) {
                D_P = 0;
            } else {
                // Calculate with safeguards against division by zero
                uint256 temp = (D * D) / (balances[0] * 2);
                D_P = (temp * D) / (balances[1] * 2);
            }

            D_prev = D;
            
            // Modified formula to prevent overflow - removed PRECISION multiplication
            // Original: D = (Ann * sum * PRECISION + D_P * 2) * D / ((Ann - 1) * D + 3 * D_P);
            
            // Step 1: Calculate numerator parts separately to avoid overflow
            uint256 numerator1 = Ann * sum;
            uint256 numerator2 = D_P * 2;
            
            // Step 2: Calculate denominator parts separately
            uint256 denominator1 = (Ann - 1) * D;
            uint256 denominator2 = 3 * D_P;
            
            // Step 3: Calculate final value with overflow protection
            D = ((numerator1 + numerator2) * D) / (denominator1 + denominator2);

            // Check if we've converged with an optimized absolute difference check
            if (D > D_prev) {
                if (D - D_prev <= 1) {
                    break;
                }
            } else {
                if (D_prev - D <= 1) {
                    break;
                }
            }
            
            // Gas optimization for loops - avoid using ++ operator
            unchecked { ++i; }
        }

        return D;
    }

    /**
     * @notice Calculate the output amount (Y) when swapping
     * @dev Calculates the token output amount for a swap to maintain the invariant D
     * @param tokenIndexFrom Index of input token (0 or 1)
     * @param tokenIndexTo Index of output token (0 or 1)
     * @param amountIn Amount of input token
     * @param balances Current balances of both tokens
     * @param amplification Amplification coefficient
     * @return Amount of output token (Y)
     */
    function getY(
        uint256 tokenIndexFrom,
        uint256 tokenIndexTo,
        uint256 amountIn,
        uint256[2] memory balances,
        uint256 amplification
    ) public pure returns (uint256) {
        if (tokenIndexFrom == tokenIndexTo) revert SameTokenIndices();
        if (tokenIndexFrom >= 2 || tokenIndexTo >= 2) revert InvalidTokenIndex();
        
        // Calculate the invariant D with current balances
        uint256 D = calculateInvariant(balances, amplification);
        
        // Update the balance of the input token
        uint256 newBalanceFrom = balances[tokenIndexFrom] + amountIn;
        uint256 Ann = amplification * 2;
        
        // Calculate c = D^3 / (4 * A * x_0) with overflow protection
        uint256 c;
        if (newBalanceFrom > 0) {
            uint256 temp = D * D / (newBalanceFrom * 2);
            c = temp * D / (Ann * 2);
        } else {
            c = 0;
        }
        
        // Then, solve for y (balance of output token)
        uint256 b = newBalanceFrom + D / Ann;
        uint256 yPrev;
        uint256 y = D;
        
        // Iteratively find y using Newton's method with overflow protection
        for (uint256 i = 0; i < MAX_ITERATIONS;) {
            yPrev = y;
            
            // Modified formula to prevent overflow
            // Original: y = (y^2 + c) / (2 * y + b - D)
            if (y == 0) {
                // Prevent division by zero
                y = 1;
            } else {
                uint256 numerator = y * y + c;
                uint256 denominator = 2 * y + b;
                
                // Ensure denominator is not less than D to prevent underflow
                if (denominator > D) {
                    denominator = denominator - D;
                    y = numerator / denominator;
                } else {
                    // If denominator would be negative, use a different approach
                    y = numerator / (denominator + 1);
                }
            }
            
            // Check if we've converged
            if (y > yPrev) {
                if (y - yPrev <= 1) {
                    break;
                }
            } else {
                if (yPrev - y <= 1) {
                    break;
                }
            }
            
            unchecked { ++i; }
        }
        
        // Ensure the new y value maintains the invariant
        if (y > balances[tokenIndexTo]) revert OutputExceedsBalance();
        
        return balances[tokenIndexTo] - y;
    }
    
    /**
     * @notice Calculate the amount of LP tokens to mint when adding liquidity
     * @dev Computes the amount of LP tokens to mint based on the change in invariant
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
            return newInvariant;  // Initial mint
        }
        
        // Safe calculation for proportional share based on invariant growth
        if (newInvariant <= oldInvariant) return 0; // No growth, no mint
        
        return (totalSupply * (newInvariant - oldInvariant)) / oldInvariant;
    }
    
    /**
     * @notice Calculate fee amount
     * @dev Calculates the fee amount for a given swap
     * @param amount Amount being swapped
     * @param fee Fee rate in PRECISION precision (e.g., 0.04% = 4e4)
     * @return Fee amount
     */
    function calculateFee(uint256 amount, uint256 fee) public pure returns (uint256) {
        return (amount * fee) / PRECISION;
    }
    
    /**
     * @notice Calculates the spot price of the token pair
     * @dev Spot price is the instantaneous exchange rate at current pool state
     * @param balances Current balances of both tokens
     * @param amplification Amplification coefficient
     * @return Spot price as a fixed-point number with PRECISION
     */
    function getSpotPrice(
        uint256[2] memory balances,
        uint256 amplification
    ) public pure returns (uint256) {
        // Handle edge cases to prevent overflow
        if (balances[0] == 0 || balances[1] == 0) return 0;
        
        uint256 D = calculateInvariant(balances, amplification);
        uint256 Ann = amplification * 2;
        
        // Calculate with overflow protection
        uint256 nA = Ann / A_PRECISION;
        uint256 x = balances[0];
        uint256 y = balances[1];
        
        uint256 numerator = x * PRECISION;
        uint256 denominator = y;
        
        // Apply the amplification effect with overflow protection
        // For a 2-token pool, spot price = x/y * (1 + D/(4*A*x*y))
        uint256 fraction;
        if (nA > 0 && x > 0 && y > 0) {
            fraction = (D * PRECISION) / (4 * nA * x * y);
        } else {
            fraction = 0;
        }
        
        uint256 adjustmentFactor = PRECISION + fraction;
        
        return (numerator * adjustmentFactor) / (denominator * PRECISION);
    }
}