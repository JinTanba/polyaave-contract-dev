#!/usr/bin/env python3
"""
High-precision oracle for verifying Core/CoreMath debt allocation formulas.
Used to generate test cases with exact expected values.
"""

from decimal import Decimal, getcontext
from typing import List, Tuple, Dict
import json

# Set very high precision for calculations
getcontext().prec = 100

# Constants
RAY = Decimal(10**27)
WAD = Decimal(10**18)
USDC_DECIMALS = 6

class DebtAllocationOracle:
    """High-precision implementation of the two-level debt allocation formula"""
    
    @staticmethod
    def calculate_market_debt(protocol_debt: Decimal, market_borrowed: Decimal, total_borrowed: Decimal) -> Decimal:
        """
        Calculate market's share of protocol debt
        marketDebt = protocolDebt * marketTotalBorrowed / totalBorrowedAllMarkets
        """
        if total_borrowed == 0:
            return Decimal(0)
        return protocol_debt * market_borrowed / total_borrowed
    
    @staticmethod
    def calculate_user_principal_debt(market_debt: Decimal, user_borrow: Decimal, market_total: Decimal) -> Decimal:
        """
        Calculate user's principal debt share
        userDebt = marketDebt * userBorrowAmount / marketTotalBorrowed
        """
        if market_total == 0:
            return Decimal(0)
        return market_debt * user_borrow / market_total
    
    @staticmethod
    def calculate_user_spread_debt(user_scaled_debt: Decimal, borrow_index: Decimal, user_borrow: Decimal) -> Decimal:
        """
        Calculate user's spread (interest) debt
        spread = (scaledDebt * borrowIndex / RAY) - borrowAmount
        """
        current_debt = user_scaled_debt * borrow_index / RAY
        return max(current_debt - user_borrow, Decimal(0))
    
    @staticmethod
    def ray_mul(a: Decimal, b: Decimal) -> Decimal:
        """Ray multiplication: (a * b + RAY/2) / RAY"""
        return (a * b + RAY // 2) // RAY
    
    @staticmethod
    def ray_div(a: Decimal, b: Decimal) -> Decimal:
        """Ray division: (a * RAY + b/2) / b"""
        if b == 0:
            raise ValueError("Division by zero")
        return (a * RAY + b // 2) // b

def generate_test_cases():
    """Generate comprehensive test cases for Solidity tests"""
    
    oracle = DebtAllocationOracle()
    test_cases = []
    
    # Test Case 1: Simple 2 markets, equal distribution
    case1 = {
        "name": "Equal distribution across 2 markets",
        "protocol_debt": 1_000_000 * 10**USDC_DECIMALS,
        "markets": [
            {
                "id": 0,
                "total_borrowed": 500_000 * 10**USDC_DECIMALS,
                "borrow_index": int(RAY),
                "users": [
                    {"borrow_amount": 100_000 * 10**USDC_DECIMALS, "scaled_debt": 100_000 * 10**USDC_DECIMALS},
                    {"borrow_amount": 200_000 * 10**USDC_DECIMALS, "scaled_debt": 200_000 * 10**USDC_DECIMALS},
                    {"borrow_amount": 200_000 * 10**USDC_DECIMALS, "scaled_debt": 200_000 * 10**USDC_DECIMALS},
                ]
            },
            {
                "id": 1,
                "total_borrowed": 500_000 * 10**USDC_DECIMALS,
                "borrow_index": int(RAY),
                "users": [
                    {"borrow_amount": 250_000 * 10**USDC_DECIMALS, "scaled_debt": 250_000 * 10**USDC_DECIMALS},
                    {"borrow_amount": 250_000 * 10**USDC_DECIMALS, "scaled_debt": 250_000 * 10**USDC_DECIMALS},
                ]
            }
        ]
    }
    
    # Test Case 2: Unequal distribution with interest accrual
    case2 = {
        "name": "Unequal distribution with different interest rates",
        "protocol_debt": 1_100_000 * 10**USDC_DECIMALS,  # 10% total interest
        "markets": [
            {
                "id": 0,
                "total_borrowed": 700_000 * 10**USDC_DECIMALS,  # 70% of borrows
                "borrow_index": int(RAY * Decimal("1.08")),     # 8% interest
                "users": [
                    {"borrow_amount": 300_000 * 10**USDC_DECIMALS, 
                     "scaled_debt": int(Decimal(300_000 * 10**USDC_DECIMALS) / Decimal("1.08"))},
                    {"borrow_amount": 400_000 * 10**USDC_DECIMALS, 
                     "scaled_debt": int(Decimal(400_000 * 10**USDC_DECIMALS) / Decimal("1.08"))},
                ]
            },
            {
                "id": 1,
                "total_borrowed": 300_000 * 10**USDC_DECIMALS,  # 30% of borrows
                "borrow_index": int(RAY * Decimal("1.15")),     # 15% interest
                "users": [
                    {"borrow_amount": 300_000 * 10**USDC_DECIMALS, 
                     "scaled_debt": int(Decimal(300_000 * 10**USDC_DECIMALS) / Decimal("1.15"))},
                ]
            }
        ]
    }
    
    # Test Case 3: Edge case - single user owns all debt in market
    case3 = {
        "name": "Single user monopoly in market",
        "protocol_debt": 500_000 * 10**USDC_DECIMALS,
        "markets": [
            {
                "id": 0,
                "total_borrowed": 500_000 * 10**USDC_DECIMALS,
                "borrow_index": int(RAY * Decimal("1.2")),
                "users": [
                    {"borrow_amount": 500_000 * 10**USDC_DECIMALS, 
                     "scaled_debt": int(Decimal(500_000 * 10**USDC_DECIMALS) / Decimal("1.2"))},
                ]
            }
        ]
    }
    
    # Test Case 4: Many markets with small amounts (rounding test)
    case4 = {
        "name": "Many markets with rounding edge cases",
        "protocol_debt": 1_000_003 * 10**USDC_DECIMALS,  # Odd number for rounding
        "markets": []
    }
    
    # Create 7 markets with prime number distributions
    primes = [13, 17, 19, 23, 29, 31, 37]
    total_shares = sum(primes)
    base_amount = 1_000_000 // total_shares
    
    for i, prime in enumerate(primes):
        market_borrow = prime * base_amount * 10**USDC_DECIMALS
        case4["markets"].append({
            "id": i,
            "total_borrowed": market_borrow,
            "borrow_index": int(RAY),
            "users": [
                {"borrow_amount": market_borrow // 3, "scaled_debt": market_borrow // 3},
                {"borrow_amount": market_borrow // 3, "scaled_debt": market_borrow // 3},
                {"borrow_amount": market_borrow - 2 * (market_borrow // 3), 
                 "scaled_debt": market_borrow - 2 * (market_borrow // 3)},
            ]
        })
    
    test_cases = [case1, case2, case3, case4]
    
    # Calculate expected values for each test case
    results = []
    for case in test_cases:
        result = process_test_case(case, oracle)
        results.append(result)
    
    return results

def process_test_case(case: Dict, oracle: DebtAllocationOracle) -> Dict:
    """Process a test case and calculate all expected values"""
    
    protocol_debt = Decimal(case["protocol_debt"])
    total_borrowed = sum(Decimal(m["total_borrowed"]) for m in case["markets"])
    
    result = {
        "name": case["name"],
        "protocol_debt": case["protocol_debt"],
        "total_borrowed_all_markets": int(total_borrowed),
        "markets": []
    }
    
    for market in case["markets"]:
        market_borrowed = Decimal(market["total_borrowed"])
        market_debt = oracle.calculate_market_debt(protocol_debt, market_borrowed, total_borrowed)
        
        market_result = {
            "id": market["id"],
            "total_borrowed": market["total_borrowed"],
            "borrow_index": market["borrow_index"],
            "expected_market_debt": int(market_debt),
            "users": []
        }
        
        sum_user_principal = Decimal(0)
        sum_user_total = Decimal(0)
        
        for user in market["users"]:
            user_borrow = Decimal(user["borrow_amount"])
            user_scaled = Decimal(user["scaled_debt"])
            borrow_index = Decimal(market["borrow_index"])
            
            # Calculate principal debt
            user_principal = oracle.calculate_user_principal_debt(market_debt, user_borrow, market_borrowed)
            
            # Calculate spread debt
            user_spread = oracle.calculate_user_spread_debt(user_scaled, borrow_index, user_borrow)
            
            # Total debt
            user_total = user_principal + user_spread
            
            user_result = {
                "borrow_amount": user["borrow_amount"],
                "scaled_debt": user["scaled_debt"],
                "expected_principal_debt": int(user_principal),
                "expected_spread_debt": int(user_spread),
                "expected_total_debt": int(user_total)
            }
            
            market_result["users"].append(user_result)
            sum_user_principal += user_principal
            sum_user_total += user_total
        
        market_result["sum_user_principal_debt"] = int(sum_user_principal)
        market_result["sum_user_total_debt"] = int(sum_user_total)
        market_result["principal_deviation"] = int(abs(sum_user_principal - market_debt))
        
        result["markets"].append(market_result)
    
    # Verify global invariants
    sum_market_debts = sum(Decimal(m["expected_market_debt"]) for m in result["markets"])
    result["sum_market_debts"] = int(sum_market_debts)
    result["protocol_debt_deviation"] = int(abs(sum_market_debts - protocol_debt))
    
    return result

def generate_solidity_test(result: Dict) -> str:
    """Generate Solidity test code from result"""
    
    test_name = result["name"].replace(" ", "_")
    code = f"""
    function test_DebtAllocation_{test_name}() public {{
        // Test: {result["name"]}
        uint256 protocolDebt = {result["protocol_debt"]};
        uint256 totalBorrowedAllMarkets = {result["total_borrowed_all_markets"]};
        
"""
    
    for market in result["markets"]:
        code += f"""        // Market {market["id"]}
        uint256 market{market["id"]}_totalBorrowed = {market["total_borrowed"]};
        uint256 market{market["id"]}_borrowIndex = {market["borrow_index"]};
        uint256 market{market["id"]}_expectedDebt = {market["expected_market_debt"]};
        
        // Verify market debt allocation
        uint256 market{market["id"]}_calculatedDebt = (protocolDebt * market{market["id"]}_totalBorrowed) / totalBorrowedAllMarkets;
        assertApproxEqAbs(market{market["id"]}_calculatedDebt, market{market["id"]}_expectedDebt, 1, 
            "Market {market["id"]} debt allocation mismatch");
        
"""
        
        for i, user in enumerate(market["users"]):
            code += f"""        // Market {market["id"]} User {i}
        uint256 m{market["id"]}_u{i}_borrowAmount = {user["borrow_amount"]};
        uint256 m{market["id"]}_u{i}_scaledDebt = {user["scaled_debt"]};
        uint256 m{market["id"]}_u{i}_expectedPrincipal = {user["expected_principal_debt"]};
        uint256 m{market["id"]}_u{i}_expectedSpread = {user["expected_spread_debt"]};
        uint256 m{market["id"]}_u{i}_expectedTotal = {user["expected_total_debt"]};
        
        // Calculate using CoreMath
        (uint256 totalDebt_{market["id"]}_{i}, uint256 principalDebt_{market["id"]}_{i}, uint256 spreadDebt_{market["id"]}_{i}) = CoreMath.calculateUserTotalDebt(
            m{market["id"]}_u{i}_borrowAmount,
            market{market["id"]}_totalBorrowed,
            m{market["id"]}_u{i}_expectedPrincipal,
            m{market["id"]}_u{i}_scaledDebt,
            market{market["id"]}_borrowIndex
        );
        
        assertApproxEqAbs(principalDebt_{market["id"]}_{i}, m{market["id"]}_u{i}_expectedPrincipal, 1, 
            "User principal debt mismatch");
        assertApproxEqAbs(spreadDebt_{market["id"]}_{i}, m{market["id"]}_u{i}_expectedSpread, 1, 
            "User spread debt mismatch");
        assertApproxEqAbs(totalDebt_{market["id"]}_{i}, m{market["id"]}_u{i}_expectedTotal, 1, 
            "User total debt mismatch");
        
"""
    
    code += """    }
"""
    return code

if __name__ == "__main__":
    print("Generating high-precision test cases for debt allocation...")
    results = generate_test_cases()
    
    # Save results as JSON
    with open("debt_allocation_test_cases.json", "w") as f:
        json.dump(results, f, indent=2)
    
    # Generate Solidity tests
    with open("DebtAllocationOracle.t.sol", "w") as f:
        f.write("""// SPDX-License-Identifier: MIT
// Generated by debt_allocation_oracle.py
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/CoreMath.sol";

contract DebtAllocationOracleTest is Test {
    uint256 constant RAY = 1e27;
""")
        
        for result in results:
            f.write(generate_solidity_test(result))
        
        f.write("}\n")
    
    print(f"Generated {len(results)} test cases")
    print("Files created:")
    print("  - debt_allocation_test_cases.json")
    print("  - DebtAllocationOracle.t.sol")