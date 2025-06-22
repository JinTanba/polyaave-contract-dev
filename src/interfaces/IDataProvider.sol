// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataStruct.sol";

interface IDataProvider {
    
    // ============ User Position Data ============
    
    /**
     * @notice Get user's position summary
     * @param user Address of the user
     * @param predictionAsset The prediction token
     * @return collateralAmount Amount of collateral deposited
     * @return borrowAmount Amount borrowed
     * @return totalDebt Current total debt (principal + interest + spread)
     * @return healthFactor Health factor (1e27 = 1.0, type(uint256).max if no debt)
     * @return maxBorrowable Maximum additional amount that can be borrowed
     */
    function getUserPositionSummary(
        address user,
        address predictionAsset
    ) external view returns (
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 totalDebt,
        uint256 healthFactor,
        uint256 maxBorrowable
    );
    
    
    // ============ Market Data ============
    
    /**
     * @notice Get market summary
     * @param predictionAsset The prediction token
     * @return isActive Whether market accepts new borrows
     * @return isResolved Whether market has been resolved
     * @return totalBorrowed Total amount borrowed in this market
     * @return totalCollateral Total collateral deposited
     * @return utilizationRate Current utilization (1e27 = 100%)
     * @return spreadRate Current spread rate (annual, 1e27 based)
     */
    function getMarketSummary(
        address predictionAsset
    ) external view returns (
        bool isActive,
        bool isResolved,
        uint256 totalBorrowed,
        uint256 totalCollateral,
        uint256 utilizationRate,
        uint256 spreadRate
    );
    
    // ============ Pool Data ============
    
    /**
     * @notice Get pool summary
     * @return totalSupplied Total amount supplied by LPs
     * @return totalBorrowed Total amount borrowed across all markets
     * @return availableLiquidity Amount available to borrow
     * @return totalLPTokens Total LP tokens in circulation
     */
    function getPoolSummary() external view returns (
        uint256 totalSupplied,
        uint256 totalBorrowed,
        uint256 availableLiquidity,
        uint256 totalLPTokens
    );
    
    // ============ Resolution Data ============
    
    /**
     * @notice Get claimable amounts after resolution
     * @param user Address of the user
     * @param predictionAsset The prediction token
     * @return borrowerClaimable Amount claimable from borrower rebate
     * @return lpClaimable Amount claimable from LP position
     */
    function getClaimableAmounts(
        address user,
        address predictionAsset
    ) external view returns (
        uint256 borrowerClaimable,
        uint256 lpClaimable
    );
    
    // ============ Configuration Data ============
    
    /**
     * @notice Get key risk parameters for UI display
     * @return supplyAsset Address of the supply asset (e.g., USDC)
     * @return ltv Loan-to-value ratio in basis points (e.g., 8000 = 80%)
     * @return liquidationThreshold Liquidation threshold in basis points
     * @return reserveFactor Protocol fee in basis points
     */
    function getRiskSummary() external view returns (
        address supplyAsset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 reserveFactor
    );
    
    // ============ Calculation Functions ============
    
    /**
     * @notice Calculate borrowable amount for given collateral
     * @param predictionAsset The prediction token to use as collateral
     * @param collateralAmount Amount of collateral to deposit
     * @return maxBorrowable Maximum amount that can be borrowed
     * @return collateralValue Value of collateral in supply asset
     */
    function calculateBorrowingPower(
        address predictionAsset,
        uint256 collateralAmount
    ) external view returns (
        uint256 maxBorrowable,
        uint256 collateralValue
    );
    
    /**
     * @notice Get user's current LTV ratio
     * @param user Address of the user
     * @param predictionAsset The prediction token
     * @return currentLTV Current LTV in basis points (e.g., 6000 = 60%)
     * @return maxLTV Maximum allowed LTV in basis points
     */
    function getUserLTV(
        address user,
        address predictionAsset
    ) external view returns (
        uint256 currentLTV,
        uint256 maxLTV
    );
    
    /**
     * @notice Check if position is healthy and can perform actions
     * @param user Address of the user
     * @param predictionAsset The prediction token
     * @return isHealthy True if position is healthy
     * @return canBorrow True if user can borrow more
     * @return canWithdrawCollateral True if user can withdraw collateral
     */
    function checkPositionHealth(
        address user,
        address predictionAsset
    ) external view returns (
        bool isHealthy,
        bool canBorrow,
        bool canWithdrawCollateral
    );
}