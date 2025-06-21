// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/Core.sol";
import "../../src/core/CoreMath.sol";
import "../../src/libraries/DataStruct.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";

/**
 * @title CoreGasRegression
 * @notice Gas regression tests for hot paths
 * @dev Ensures gas usage doesn't increase beyond acceptable thresholds
 */
contract CoreGasRegression is Test {
    using WadRayMath for uint256;
    
    Core internal core;
    
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;
    
    // Gas limits for hot paths (10% tolerance)
    uint256 internal constant SUPPLY_GAS_LIMIT = 8_200;      // 7,456 + 10%
    uint256 internal constant BORROW_GAS_LIMIT = 43_970;    // 39,972 + 10%
    uint256 internal constant REPAY_GAS_LIMIT = 35_000;     // Estimated
    uint256 internal constant UPDATE_INDEX_GAS_LIMIT = 25_000; // Estimated
    uint256 internal constant CALCULATE_DEBT_GAS_LIMIT = 5_000; // Pure function
    
    RiskParams internal params;
    PoolData internal pool;
    MarketData internal market;
    UserPosition internal position;
    
    function setUp() public {
        core = new Core();
        
        params = RiskParams({
            priceOracle: address(0x1),
            liquidityLayer: address(0x2),
            supplyAsset: address(0x3),
            curator: address(0x4),
            baseSpreadRate: 1e25,
            optimalUtilization: 8e26,
            slope1: 5e25,
            slope2: 2e26,
            reserveFactor: 1000,
            ltv: 7500,
            liquidationThreshold: 8000,
            liquidationCloseFactor: 5000,
            liquidationBonus: 500,
            lpShareOfRedeemed: 5000,
            supplyAssetDecimals: 6
        });
        
        // Setup initial state
        pool.totalSupplied = 1_000_000 * 1e6;
        pool.totalBorrowedAllMarkets = 500_000 * 1e6;
        
        market.variableBorrowIndex = RAY;
        market.totalBorrowed = 500_000 * 1e6;
        market.totalScaledBorrowed = 500_000 * 1e6;
        market.collateralAssetDecimals = 18;
        market.lastUpdateTimestamp = block.timestamp;
        
        position.borrowAmount = 10_000 * 1e6;
        position.scaledDebtBalance = 10_000 * 1e6;
        position.collateralAmount = 10 * WAD;
    }
    
    function test_GasRegression_ProcessSupply() public {
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: 1000 * 1e6,
            supplyAmount: 1000 * 1e6
        });
        
        uint256 gasStart = gasleft();
        core.processSupply(pool, input);
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("processSupply gas used", gasUsed);
        
        assertLt(gasUsed, SUPPLY_GAS_LIMIT, 
            string.concat(
                "processSupply gas regression: ",
                "used ", vm.toString(gasUsed),
                " > limit ", vm.toString(SUPPLY_GAS_LIMIT)
            )
        );
    }
    
    function test_GasRegression_ProcessBorrow() public {
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: 1000 * 1e6,
            collateralAmount: 1 * WAD,
            collateralPrice: 2000 * RAY,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        uint256 gasStart = gasleft();
        core.processBorrow(market, pool, position, input, params);
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("processBorrow gas used", gasUsed);
        
        assertLt(gasUsed, BORROW_GAS_LIMIT,
            string.concat(
                "processBorrow gas regression: ",
                "used ", vm.toString(gasUsed),
                " > limit ", vm.toString(BORROW_GAS_LIMIT)
            )
        );
    }
    
    function test_GasRegression_ProcessRepay() public {
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: 5000 * 1e6,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        uint256 gasStart = gasleft();
        core.processRepay(market, pool, position, input);
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("processRepay gas used", gasUsed);
        
        assertLt(gasUsed, REPAY_GAS_LIMIT,
            string.concat(
                "processRepay gas regression: ",
                "used ", vm.toString(gasUsed),
                " > limit ", vm.toString(REPAY_GAS_LIMIT)
            )
        );
    }
    
    function test_GasRegression_UpdateMarketIndices() public {
        // Advance time to trigger index update
        skip(1 days);
        
        uint256 gasStart = gasleft();
        core.updateMarketIndices(market, pool, params, block.timestamp);
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("updateMarketIndices gas used", gasUsed);
        
        assertLt(gasUsed, UPDATE_INDEX_GAS_LIMIT,
            string.concat(
                "updateMarketIndices gas regression: ",
                "used ", vm.toString(gasUsed),
                " > limit ", vm.toString(UPDATE_INDEX_GAS_LIMIT)
            )
        );
    }
    
    function test_GasRegression_CalculateUserTotalDebt() public {
        uint256 gasStart = gasleft();
        CoreMath.calculateUserTotalDebt(
            position.borrowAmount,
            market.totalBorrowed,
            position.borrowAmount, // principal debt
            position.scaledDebtBalance,
            market.variableBorrowIndex
        );
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("calculateUserTotalDebt gas used", gasUsed);
        
        assertLt(gasUsed, CALCULATE_DEBT_GAS_LIMIT,
            string.concat(
                "calculateUserTotalDebt gas regression: ",
                "used ", vm.toString(gasUsed),
                " > limit ", vm.toString(CALCULATE_DEBT_GAS_LIMIT)
            )
        );
    }
    
    function test_GasRegression_ComplexScenario() public {
        // Test a complex scenario with multiple operations
        uint256 totalGasUsed = 0;
        
        // 1. Supply
        uint256 gasStart = gasleft();
        CoreSupplyInput memory supplyInput = CoreSupplyInput({
            userLPBalance: 0,
            supplyAmount: 10_000 * 1e6
        });
        (pool,) = core.processSupply(pool, supplyInput);
        totalGasUsed += gasStart - gasleft();
        
        // 2. Borrow
        gasStart = gasleft();
        CoreBorrowInput memory borrowInput = CoreBorrowInput({
            borrowAmount: 5000 * 1e6,
            collateralAmount: 5 * WAD,
            collateralPrice: 2000 * RAY,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        (market, pool, position,) = core.processBorrow(market, pool, position, borrowInput, params);
        totalGasUsed += gasStart - gasleft();
        
        // 3. Time passes - update indices
        skip(7 days);
        gasStart = gasleft();
        (market, pool) = core.updateMarketIndices(market, pool, params, block.timestamp);
        totalGasUsed += gasStart - gasleft();
        
        // 4. Partial repay
        gasStart = gasleft();
        CoreRepayInput memory repayInput = CoreRepayInput({
            repayAmount: 2500 * 1e6,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        core.processRepay(market, pool, position, repayInput);
        totalGasUsed += gasStart - gasleft();
        
        emit log_named_uint("Complex scenario total gas", totalGasUsed);
        
        // Complex scenario should be reasonably efficient
        uint256 complexGasLimit = SUPPLY_GAS_LIMIT + BORROW_GAS_LIMIT + UPDATE_INDEX_GAS_LIMIT + REPAY_GAS_LIMIT;
        assertLt(totalGasUsed, complexGasLimit,
            "Complex scenario gas usage exceeds individual operation sum"
        );
    }
    
    function test_GasRegression_WorstCase() public {
        // Test worst-case gas usage with maximum values
        
        // Setup extreme but valid state
        pool.totalSupplied = 1e12 * 1e6; // 1 trillion USDC
        pool.totalBorrowedAllMarkets = 8e11 * 1e6; // 800 billion (80% utilization)
        
        market.variableBorrowIndex = 2 * RAY; // 2x growth
        market.totalBorrowed = 8e11 * 1e6;
        market.totalScaledBorrowed = 4e11 * 1e6;
        
        position.borrowAmount = 1e9 * 1e6; // 1 billion
        position.scaledDebtBalance = 5e8 * 1e6;
        position.collateralAmount = 1e6 * WAD; // 1M tokens
        
        // Borrow operation with large values
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: 1e8 * 1e6, // 100M
            collateralAmount: 1e5 * WAD, // 100k tokens
            collateralPrice: 10_000 * RAY, // $10k per token
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        uint256 gasStart = gasleft();
        core.processBorrow(market, pool, position, input, params);
        uint256 gasUsed = gasStart - gasleft();
        
        emit log_named_uint("Worst case borrow gas", gasUsed);
        
        // Even worst case should be within 2x normal limit
        assertLt(gasUsed, BORROW_GAS_LIMIT * 2,
            "Worst case gas usage should not exceed 2x normal"
        );
    }
    
    /**
     * @notice Generate gas snapshot for CI comparison
     * @dev Run with: forge test --match-test test_GenerateGasSnapshot -vv
     */
    function test_GenerateGasSnapshot() public {
        string memory snapshot = "";
        
        // Test each operation and collect gas usage
        uint256 supplyGas = _measureGas_Supply();
        uint256 borrowGas = _measureGas_Borrow();
        uint256 repayGas = _measureGas_Repay();
        uint256 updateGas = _measureGas_UpdateIndex();
        uint256 debtCalcGas = _measureGas_DebtCalculation();
        
        // Create snapshot JSON
        snapshot = string.concat(
            "{\n",
            '  "processSupply": ', vm.toString(supplyGas), ",\n",
            '  "processBorrow": ', vm.toString(borrowGas), ",\n",
            '  "processRepay": ', vm.toString(repayGas), ",\n",
            '  "updateMarketIndices": ', vm.toString(updateGas), ",\n",
            '  "calculateUserTotalDebt": ', vm.toString(debtCalcGas), ",\n",
            '  "timestamp": ', vm.toString(block.timestamp), "\n",
            "}"
        );
        
        // Write to file (would be read by CI)
        emit log_string("=== GAS SNAPSHOT ===");
        emit log_string(snapshot);
        emit log_string("====================");
    }
    
    function _measureGas_Supply() internal returns (uint256) {
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: 1000 * 1e6,
            supplyAmount: 1000 * 1e6
        });
        
        uint256 gasStart = gasleft();
        core.processSupply(pool, input);
        return gasStart - gasleft();
    }
    
    function _measureGas_Borrow() internal returns (uint256) {
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: 1000 * 1e6,
            collateralAmount: 1 * WAD,
            collateralPrice: 2000 * RAY,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        uint256 gasStart = gasleft();
        core.processBorrow(market, pool, position, input, params);
        return gasStart - gasleft();
    }
    
    function _measureGas_Repay() internal returns (uint256) {
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: 5000 * 1e6,
            protocolTotalDebt: pool.totalBorrowedAllMarkets
        });
        
        uint256 gasStart = gasleft();
        core.processRepay(market, pool, position, input);
        return gasStart - gasleft();
    }
    
    function _measureGas_UpdateIndex() internal returns (uint256) {
        skip(1 days);
        
        uint256 gasStart = gasleft();
        core.updateMarketIndices(market, pool, params, block.timestamp);
        return gasStart - gasleft();
    }
    
    function _measureGas_DebtCalculation() internal returns (uint256) {
        uint256 gasStart = gasleft();
        CoreMath.calculateUserTotalDebt(
            position.borrowAmount,
            market.totalBorrowed,
            position.borrowAmount,
            position.scaledDebtBalance,
            market.variableBorrowIndex
        );
        return gasStart - gasleft();
    }
}