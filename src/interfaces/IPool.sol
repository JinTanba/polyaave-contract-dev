// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../libraries/DataStruct.sol";

interface IPool {
    // ============ Core Functions ============
    
    /**
     * @notice Supply liquidity to the pool
     * @param amount Amount of supply asset to deposit
     * @return lpTokensMinted Amount of LP tokens minted
     */
    function supply(uint256 amount) external returns (uint256 lpTokensMinted);
    
    /**
     * @notice Borrow against collateral
     * @param predictionAsset Address of the prediction token
     * @param collateralAmount Amount of prediction tokens to deposit
     * @param borrowAmount Amount to borrow
     * @return actualBorrowAmount Amount actually borrowed
     */
    function borrow(
        address predictionAsset,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external returns (uint256 actualBorrowAmount);
    
    /**
     * @notice Repay borrowed amount
     * @param predictionAsset Address of the prediction token
     * @param repayAmount Amount to repay
     * @return actualRepayAmount Amount actually repaid
     */
    function repay(
        address predictionAsset,
        uint256 repayAmount
    ) external returns (uint256 actualRepayAmount);
    
    /**
     * @notice Liquidate an undercollateralized position
     * @param user Address being liquidated
     * @param predictionAsset The prediction token used as collateral
     * @param debtToCover Amount of debt to repay
     * @return actualDebtRepaid Actual amount of debt repaid
     * @return collateralSeized Amount of collateral seized
     */
    function liquidate(
        address user,
        address predictionAsset,
        uint256 debtToCover
    ) external returns (
        uint256 actualDebtRepaid,
        uint256 collateralSeized
    );
    
    // ============ Resolution Functions ============
    
    /**
     * @notice Resolve a prediction market
     * @param predictionAsset The prediction token being resolved
     */
    function resolveMarket(address predictionAsset) external;
    
    /**
     * @notice Claim borrower's rebate after resolution
     * @param predictionAsset The prediction token
     * @return rebateAmount Amount of rebate claimed
     */
    function claimBorrowerPosition(
        address predictionAsset
    ) external returns (uint256 rebateAmount);
    
    /**
     * @notice Claim LP position after resolution
     * @param lpTokenAmount Amount of LP tokens to redeem
     * @return totalPayout Total amount paid to LP
     */
    function claimLPPosition(
        uint256 lpTokenAmount
    ) external returns (uint256 totalPayout);
    
    /**
     * @notice Claim protocol revenues
     * @return protocolAmount Amount claimed
     */
    function claimProtocolRevenue() external returns (uint256 protocolAmount);
    
    // ============ Admin Functions ============
    
    /**
     * @notice Initialize a new prediction market
     * @param predictionAsset The prediction token address
     * @param collateralDecimals The collateral asset decimals
     */
    function initializeMarket(
        address predictionAsset,
        uint256 collateralDecimals
    ) external;
    
}