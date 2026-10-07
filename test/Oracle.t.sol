// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {FrogOracle} from "../src/FrogOracle.sol";

contract OracleHarness is FrogOracle {
    function record(int24 tick) external {
        _record(tick);
    }
}

contract OracleTest is Test {
    OracleHarness oracle;

    function setUp() public {
        oracle = new OracleHarness();
        vm.warp(1000000);
        oracle.record(0);
    }

    function testWarmupHistoryInterpolationAndNegativeRounding() public {
        vm.warp(1001799);
        vm.expectRevert(FrogOracle.OracleNotReady.selector);
        oracle.consult();
        vm.warp(1001800);
        assertEq(oracle.consult(), 0);
        oracle.record(-1);
        vm.warp(1001801);
        assertEq(oracle.consult(), -1, "negative mean tick rounds down");
        vm.warp(1003600);
        assertEq(oracle.consult(), -1);
        oracle.record(100);
        assertEq(oracle.consult(), -1, "spot cannot rewrite history");
    }

    function testRingWrapAndRapidUpdatesCannotEraseHistory() public {
        for (uint256 i = 1; i <= 100; i++) {
            vm.warp(1000000 + i * 60);
            oracle.record(10);
            oracle.record(10);
        }
        assertEq(oracle.observationCount(), 64);
        assertEq(oracle.consult(), 10);
        vm.warp(1006061);
        oracle.record(10);
        assertEq(oracle.consult(), 10);
        assertEq(oracle.quoteAtTick(0, 100 ether, true), 100 ether);
        assertEq(oracle.quoteAtTick(0, 100 ether, false), 100 ether);
    }
}
