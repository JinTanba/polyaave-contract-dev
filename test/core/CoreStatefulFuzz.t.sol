// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Core.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";

/**
 * @title CoreStatefulFuzz
 * @notice Comprehensive stateful fuzzing to ensure protocol invariants hold after EVERY state mutation
 * @dev Tests the three critical invariants with millions of random operations
 */
contract CoreStatefulFuzz is Test {
    using WadRayMath for uint256;
    
    Core internal core;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_MARKETS = 10;
    uint256 internal constant MAX_USERS = 50;
    uint256 internal constant MAX_OPERATIONS = 1_000_000;
    
    // Protocol state
    PoolData internal pool;
    MarketData[] internal markets;
    mapping(uint256 => mapping(uint256 => UserPosition)) internal positions; // marketId => userId => position
    mapping(uint256 => uint256) internal lpBalances; // userId => balance
    
    // Tracking for invariants
    uint256 internal totalLPSupply;
    uint256 internal totalProtocolDebt;
    
    // Risk parameters
    RiskParams internal params;
    
    // Operation counters for coverage
    uint256 internal supplyCount;
    uint256 internal borrowCount;
    uint256 internal repayCount;
    uint256 internal partialRepayCount;
    uint256 internal crossMarketCount;
    uint256 internal timeAdvanceCount;
    
    function setUp() public {
        core = new Core();
        
        params = RiskParams({
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            curator: address(0x4),
            baseSpreadRate: 1e25, // 1% in Ray
            optimalUtilization: 8e26, // 80% in Ray
            slope1: 5e25, // 5% in Ray
            slope2: 2e26, // 20% in Ray
            reserveFactor: 1000, // 10%
            ltv: 7500, // 75%
            liquidationThreshold: 8000, // 80%
            liquidationCloseFactor: 5000, // 50%
            liquidationBonus: 500, // 5%
            lpShareOfRedeemed: 5000, // 50%
            supplyAssetDecimals: 6
        });
        
        // Initialize markets
        for (uint i = 0; i < MAX_MARKETS; i++) {
            MarketData memory market;
            market.variableBorrowIndex = RAY;
            market.lastUpdateTimestamp = block.timestamp;
            market.collateralAssetDecimals = 18;
            markets.push(market);
        }
    }
    
    /**
     * @notice Main stateful fuzzing function - runs millions of random operations
     * @dev Each operation is followed by invariant checks
     */
    function testStatefulProtocolInvariants() public {
        // Run a large number of operations
        for (uint i = 0; i < MAX_OPERATIONS; i++) {
            // Generate random operation
            uint256 opType = uint256(keccak256(abi.encode(i, "op"))) % 100;
            
            if (opType < 30) {
                // 30% chance: Supply
                _randomSupply(i);
            } else if (opType < 50) {
                // 20% chance: Borrow
                _randomBorrow(i);
            } else if (opType < 65) {
                // 15% chance: Full repay
                _randomFullRepay(i);
            } else if (opType < 80) {
                // 15% chance: Partial repay
                _randomPartialRepay(i);
            } else if (opType < 90) {
                // 10% chance: Cross-market operation
                _randomCrossMarket(i);
            } else {
                // 10% chance: Time advance
                _randomTimeAdvance(i);
            }
            
            // Check all invariants after EVERY operation
            _checkInvariant1_LPBalance();
            _checkInvariant2_MarketDebt();
            _checkInvariant3_Solvency();
            _checkDebtAllocationFormula();
            
            // Log progress every 10k operations
            if (i % 10000 == 0) {
                emit log_named_uint("Operations completed", i);
                emit log_named_uint("Supply operations", supplyCount);
                emit log_named_uint("Borrow operations", borrowCount);
                emit log_named_uint("Repay operations", repayCount);
                emit log_named_uint("Partial repay operations", partialRepayCount);
                emit log_named_uint("Cross-market operations", crossMarketCount);
            }
        }
        
        // Final statistics
        emit log_string("=== Final Statistics ===");
        emit log_named_uint("Total operations", MAX_OPERATIONS);
        emit log_named_uint("Supply count", supplyCount);
        emit log_named_uint("Borrow count", borrowCount);
        emit log_named_uint("Full repay count", repayCount);
        emit log_named_uint("Partial repay count", partialRepayCount);
        emit log_named_uint("Cross-market count", crossMarketCount);
        emit log_named_uint("Time advances", timeAdvanceCount);
    }
    
    // ============ Random Operations ============
    
    function _randomSupply(uint256 seed) internal {
        uint256 userId = uint256(keccak256(abi.encode(seed, "user"))) % MAX_USERS;
        uint256 amount = _boundAmount(uint256(keccak256(abi.encode(seed, "amount"))), 1e6, 1e12);
        
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: lpBalances[userId],
            supplyAmount: amount
        });
        
        (PoolData memory newPool, CoreSupplyOutput memory output) = core.processSupply(pool, input);
        
        // Update state
        pool = newPool;
        lpBalances[userId] = output.newUserLPBalance;
        totalLPSupply += output.lpTokensToMint;
        supplyCount++;
    }
    
    function _randomBorrow(uint256 seed) internal {
        if (pool.totalSupplied == 0) return;
        
        uint256 marketId = uint256(keccak256(abi.encode(seed, "market"))) % markets.length;
        uint256 userId = uint256(keccak256(abi.encode(seed, "user"))) % MAX_USERS;
        
        uint256 availableLiquidity = pool.totalSupplied > pool.totalBorrowedAllMarkets 
            ? pool.totalSupplied - pool.totalBorrowedAllMarkets 
            : 0;
        
        if (availableLiquidity < 1e6) return;
        
        uint256 borrowAmount = _boundAmount(
            uint256(keccak256(abi.encode(seed, "borrow"))), 
            1e6, 
            availableLiquidity / 2
        );
        
        // Generate collateral
        uint256 collateralPrice = _boundAmount(
            uint256(keccak256(abi.encode(seed, "price"))),
            RAY / 100, // $0.01
            100_000 * RAY // $100k
        );
        
        uint256 requiredCollateralValue = (borrowAmount * 10_000) / params.ltv;
        uint256 collateralAmount = (requiredCollateralValue * WAD * 1e6) / collateralPrice;
        
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            collateralPrice: collateralPrice,
            protocolTotalDebt: totalProtocolDebt
        });
        
        (MarketData memory newMarket,
         PoolData memory newPool,
         UserPosition memory newPosition,
         CoreBorrowOutput memory output) = core.processBorrow(
            markets[marketId],
            pool,
            positions[marketId][userId],
            input,
            params
        );
        
        // Update state
        markets[marketId] = newMarket;
        pool = newPool;
        positions[marketId][userId] = newPosition;
        totalProtocolDebt = newPool.totalBorrowedAllMarkets;
        borrowCount++;
    }
    
    function _randomFullRepay(uint256 seed) internal {
        (uint256 marketId, uint256 userId, bool found) = _findBorrower(seed);
        if (!found) return;
        
        UserPosition memory position = positions[marketId][userId];
        if (position.borrowAmount == 0) return;
        
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: position.borrowAmount,
            protocolTotalDebt: totalProtocolDebt
        });
        
        (MarketData memory newMarket,
         PoolData memory newPool,
         UserPosition memory newPosition,
         CoreRepayOutput memory output) = core.processRepay(
            markets[marketId],
            pool,
            position,
            input
        );
        
        // Update state
        markets[marketId] = newMarket;
        pool = newPool;
        positions[marketId][userId] = newPosition;
        totalProtocolDebt = newPool.totalBorrowedAllMarkets;
        repayCount++;
    }
    
    function _randomPartialRepay(uint256 seed) internal {
        (uint256 marketId, uint256 userId, bool found) = _findBorrower(seed);
        if (!found) return;
        
        UserPosition memory position = positions[marketId][userId];
        if (position.borrowAmount == 0) return;
        
        // Random percentage between 1% and 99%
        uint256 repayPercent = (uint256(keccak256(abi.encode(seed, "percent"))) % 98) + 1;
        uint256 repayAmount = (position.borrowAmount * repayPercent) / 100;
        
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: repayAmount,
            protocolTotalDebt: totalProtocolDebt
        });
        
        (MarketData memory newMarket,
         PoolData memory newPool,
         UserPosition memory newPosition,
         CoreRepayOutput memory output) = core.processRepay(
            markets[marketId],
            pool,
            position,
            input
        );
        
        // Update state
        markets[marketId] = newMarket;
        pool = newPool;
        positions[marketId][userId] = newPosition;
        totalProtocolDebt = newPool.totalBorrowedAllMarkets;
        partialRepayCount++;
        
        // Verify proportional collateral return
        uint256 expectedCollateralReturn = (position.collateralAmount * repayPercent) / 100;
        assertApproxEqAbs(
            output.collateralToReturn, 
            expectedCollateralReturn, 
            1,
            "Partial repay must return proportional collateral"
        );
    }
    
    function _randomCrossMarket(uint256 seed) internal {
        if (markets.length < 2) return;
        
        uint256 userId = uint256(keccak256(abi.encode(seed, "user"))) % MAX_USERS;
        uint256 marketA = uint256(keccak256(abi.encode(seed, "marketA"))) % markets.length;
        uint256 marketB = uint256(keccak256(abi.encode(seed, "marketB"))) % markets.length;
        
        if (marketA == marketB) {
            marketB = (marketA + 1) % markets.length;
        }
        
        // First borrow in market A
        _borrowInMarket(seed, marketA, userId);
        
        // Then borrow in market B
        _borrowInMarket(seed * 2, marketB, userId);
        
        crossMarketCount++;
    }
    
    function _randomTimeAdvance(uint256 seed) internal {
        uint256 timeDelta = _boundAmount(
            uint256(keccak256(abi.encode(seed, "time"))),
            1,
            30 days
        );
        
        // Advance time
        skip(timeDelta);
        
        // Update all market indices
        for (uint i = 0; i < markets.length; i++) {
            (MarketData memory newMarket, PoolData memory newPool) = core.updateMarketIndices(
                markets[i],
                pool,
                params,
                block.timestamp
            );
            
            // Verify monotonicity
            assertGe(
                newMarket.variableBorrowIndex,
                markets[i].variableBorrowIndex,
                "Borrow index must be monotonically increasing"
            );
            
            markets[i] = newMarket;
            pool = newPool;
        }
        
        timeAdvanceCount++;
    }
    
    // ============ Invariant Checks ============
    
    function _checkInvariant1_LPBalance() internal view {
        assertEq(
            totalLPSupply,
            pool.totalSupplied,
            "INVARIANT 1 VIOLATED: sum(lpBalances) != pool.totalSupplied"
        );
    }
    
    function _checkInvariant2_MarketDebt() internal view {
        uint256 sumMarketDebts = 0;
        for (uint i = 0; i < markets.length; i++) {
            sumMarketDebts += markets[i].totalBorrowed;
        }
        
        assertEq(
            sumMarketDebts,
            pool.totalBorrowedAllMarkets,
            "INVARIANT 2 VIOLATED: sum(market.totalBorrowed) != pool.totalBorrowedAllMarkets"
        );
    }
    
    function _checkInvariant3_Solvency() internal view {
        assertLe(
            pool.totalBorrowedAllMarkets,
            pool.totalSupplied,
            "INVARIANT 3 VIOLATED: totalBorrowedAllMarkets > totalSupplied"
        );
    }
    
    function _checkDebtAllocationFormula() internal view {
        if (pool.totalBorrowedAllMarkets == 0) return;
        
        // For each market with debt
        for (uint m = 0; m < markets.length; m++) {
            if (markets[m].totalBorrowed == 0) continue;
            
            // Calculate expected market debt share
            uint256 expectedMarketDebt = (totalProtocolDebt * markets[m].totalBorrowed) / pool.totalBorrowedAllMarkets;
            
            // For each user with debt in this market
            uint256 sumUserDebts = 0;
            for (uint u = 0; u < MAX_USERS; u++) {
                if (positions[m][u].borrowAmount == 0) continue;
                
                // Calculate user's share using the two-level formula
                uint256 userPrincipalDebt = (expectedMarketDebt * positions[m][u].borrowAmount) / markets[m].totalBorrowed;
                
                // Get actual debt from CoreMath
                (uint256 actualTotalDebt, uint256 actualPrincipal,) = CoreMath.calculateUserTotalDebt(
                    positions[m][u].borrowAmount,
                    markets[m].totalBorrowed,
                    userPrincipalDebt,
                    positions[m][u].scaledDebtBalance,
                    markets[m].variableBorrowIndex
                );
                
                // Verify principal calculation matches
                assertApproxEqAbs(
                    actualPrincipal,
                    userPrincipalDebt,
                    1,
                    "User principal debt must match two-level formula"
                );
                
                sumUserDebts += positions[m][u].borrowAmount;
            }
            
            // Sum of user borrow amounts should equal market total
            assertEq(
                sumUserDebts,
                markets[m].totalBorrowed,
                "Sum of user borrows must equal market total"
            );
        }
    }
    
    // ============ Helper Functions ============
    
    function _boundAmount(uint256 raw, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max <= min) return min;
        return min + (raw % (max - min + 1));
    }
    
    function _findBorrower(uint256 seed) internal view returns (uint256 marketId, uint256 userId, bool found) {
        // Try random selection first
        for (uint attempt = 0; attempt < 10; attempt++) {
            marketId = uint256(keccak256(abi.encode(seed, attempt, "market"))) % markets.length;
            userId = uint256(keccak256(abi.encode(seed, attempt, "user"))) % MAX_USERS;
            
            if (positions[marketId][userId].borrowAmount > 0) {
                return (marketId, userId, true);
            }
        }
        
        // Fallback: linear search
        for (uint m = 0; m < markets.length; m++) {
            for (uint u = 0; u < MAX_USERS; u++) {
                if (positions[m][u].borrowAmount > 0) {
                    return (m, u, true);
                }
            }
        }
        
        return (0, 0, false);
    }
    
    function _borrowInMarket(uint256 seed, uint256 marketId, uint256 userId) internal {
        uint256 availableLiquidity = pool.totalSupplied > pool.totalBorrowedAllMarkets 
            ? pool.totalSupplied - pool.totalBorrowedAllMarkets 
            : 0;
        
        if (availableLiquidity < 1e6) return;
        
        uint256 borrowAmount = _boundAmount(
            uint256(keccak256(abi.encode(seed, "amount"))),
            1e6,
            availableLiquidity / 4
        );
        
        uint256 collateralPrice = _boundAmount(
            uint256(keccak256(abi.encode(seed, "price"))),
            100 * RAY,
            10_000 * RAY
        );
        
        uint256 requiredCollateralValue = (borrowAmount * 10_000) / params.ltv;
        uint256 collateralAmount = (requiredCollateralValue * WAD * 1e6) / collateralPrice;
        
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            collateralPrice: collateralPrice,
            protocolTotalDebt: totalProtocolDebt
        });
        
        (MarketData memory newMarket,
         PoolData memory newPool,
         UserPosition memory newPosition,) = core.processBorrow(
            markets[marketId],
            pool,
            positions[marketId][userId],
            input,
            params
        );
        
        markets[marketId] = newMarket;
        pool = newPool;
        positions[marketId][userId] = newPosition;
        totalProtocolDebt = newPool.totalBorrowedAllMarkets;
    }
}