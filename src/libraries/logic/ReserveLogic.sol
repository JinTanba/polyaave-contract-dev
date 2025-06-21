// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../StorageShell.sol";
import "../DataStruct.sol";
import "../../core/Core.sol";

/**
 * @title ReserveLogic
 * @notice Library for standardized reserve operations, particularly index updates
 * @dev Centralizes the pattern: update indices -> store -> continue with operation
 */
library ReserveLogic {
    bytes32 internal constant ZERO_ID = bytes32(0);
    
    /**
     * @notice Update market indices and store the results
     * @dev This function encapsulates the standard pattern of:
     *      1. Update indices via Core
     *      2. Store updated market data
     *      3. Store updated pool data
     * @param marketId The market identifier
     * @return market Updated market data
     * @return pool Updated pool data
     */
    function updateAndStoreMarketIndices(
        bytes32 marketId
    ) internal returns (
        MarketData memory market,
        PoolData memory pool
    ) {
        // Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        market = StorageShell.getMarketData(marketId);
        pool = StorageShell.getPool();
        
        // Update indices via Core
        Core core = Core(address(this));
        (market, pool) = core.updateMarketIndices(market, pool, params, block.timestamp);
        
        // Store updated state immediately
        StorageShell.next(DataType.MARKET_DATA, abi.encode(market), marketId);
        StorageShell.next(DataType.POOL_DATA, abi.encode(pool), ZERO_ID);
        
        return (market, pool);
    }
    
    /**
     * @notice Update market indices without storing (for view functions)
     * @dev Use this for read-only operations that need current index values
     * @param marketId The market identifier
     * @return market Updated market data
     * @return pool Updated pool data
     */
    function getUpdatedMarketIndices(
        bytes32 marketId
    ) internal view returns (
        MarketData memory market,
        PoolData memory pool
    ) {
        // Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        market = StorageShell.getMarketData(marketId);
        pool = StorageShell.getPool();
        
        // Update indices via Core (view only)
        Core core = Core(address(this));
        (market, pool) = core.updateMarketIndices(market, pool, params, block.timestamp);
        
        return (market, pool);
    }
    
    /**
     * @notice Update indices for multiple markets
     * @dev Useful for operations that affect multiple markets (like supply)
     * @param marketIds Array of market identifiers to update
     * @return pool Final updated pool data after all market updates
     */
    function updateMultipleMarketIndices(
        bytes32[] memory marketIds
    ) internal returns (PoolData memory pool) {
        if (marketIds.length == 0) {
            return StorageShell.getPool();
        }
        
        RiskParams memory params = StorageShell.getRiskParams();
        Core core = Core(address(this));
        pool = StorageShell.getPool();
        
        for (uint256 i = 0; i < marketIds.length; i++) {
            MarketData memory market = StorageShell.getMarketData(marketIds[i]);
            
            // Skip if market is not active or never had any borrows
            if (!market.isActive || market.lastUpdateTimestamp == 0) {
                continue;
            }
            
            // Update indices
            (market, pool) = core.updateMarketIndices(market, pool, params, block.timestamp);
            
            // Store updated market
            StorageShell.next(DataType.MARKET_DATA, abi.encode(market), marketIds[i]);
        }
        
        // Store final pool state once after all updates
        StorageShell.next(DataType.POOL_DATA, abi.encode(pool), ZERO_ID);
        
        return pool;
    }
    
    /**
     * @notice Initialize a new market
     * @dev Sets initial index values for a new market
     * @param marketId The market identifier
     * @param collateralAsset The collateral asset address
     * @param collateralDecimals The collateral asset decimals
     */
    function initializeMarket(
        bytes32 marketId,
        address collateralAsset,
        uint256 collateralDecimals
    ) internal {
        MarketData memory market = StorageShell.getMarketData(marketId);
        
        // Only initialize if not already initialized
        if (market.variableBorrowIndex == 0) {
            market.collateralAsset = collateralAsset;
            market.collateralAssetDecimals = collateralDecimals;
            market.variableBorrowIndex = 1e27; // RAY
            market.lastUpdateTimestamp = block.timestamp;
            market.isActive = true;
            
            StorageShell.next(DataType.MARKET_DATA, abi.encode(market), marketId);
        }
    }
    
    /**
     * @notice Deactivate a market
     * @dev Prevents further borrows but allows repayments
     * @param marketId The market identifier
     */
    function deactivateMarket(bytes32 marketId) internal {
        MarketData memory market = StorageShell.getMarketData(marketId);
        market.isActive = false;
        StorageShell.next(DataType.MARKET_DATA, abi.encode(market), marketId);
    }
    
    /**
     * @notice Mark a market as matured
     * @dev Called when the underlying prediction market matures
     * @param marketId The market identifier
     */
    function setMarketMatured(bytes32 marketId) internal {
        MarketData memory market = StorageShell.getMarketData(marketId);
        market.isMatured = true;
        market.maturityDate = block.timestamp;
        StorageShell.next(DataType.MARKET_DATA, abi.encode(market), marketId);
    }
}