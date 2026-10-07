// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice 64 cumulative-tick observations, at least 60 seconds apart.
/// Used exclusively to put a protocol floor on permissionless vault buybacks.
abstract contract FrogOracle {
    struct Observation {
        uint64 time;
        int192 cumulative;
    }
    Observation[64] public observations;
    uint8 public observationIndex;
    uint8 public observationCount;
    int24 public lastTick;
    uint64 public lastObservationTime;
    int192 public tickCumulative;
    error OracleNotReady();

    function _record(int24 tick) internal {
        uint64 now_ = uint64(block.timestamp);
        int192 cumulative = tickCumulative + int192(lastTick) * int192(uint192(now_ - lastObservationTime));
        tickCumulative = cumulative;
        lastObservationTime = now_;
        lastTick = tick;
        if (observationCount == 0) {
            observationCount = 1;
            observations[0] = Observation(now_, cumulative);
        } else if (now_ >= observations[observationIndex].time + 60) {
            observationIndex = (observationIndex + 1) % 64;
            observations[observationIndex] = Observation(now_, cumulative);
            if (observationCount < 64) observationCount++;
        }
    }

    function consult() public view returns (int24 meanTick) {
        uint64 now_ = uint64(block.timestamp);
        if (observationCount == 0 || now_ < 1800) revert OracleNotReady();
        uint64 targetTime = now_ - 1800;
        int192 nowCumulative = tickCumulative + int192(lastTick) * int192(uint192(now_ - lastObservationTime));
        Observation memory upper = Observation(now_, nowCumulative);
        Observation memory lower;
        bool found;
        // Walk newest to oldest. Cumulative interpolation limits storage to 64 observations.
        for (uint256 i; i < observationCount; ++i) {
            Observation memory o = observations[(uint256(observationIndex) + 64 - i) % 64];
            if (o.time <= targetTime) {
                lower = o;
                found = true;
                break;
            }
            upper = o;
        }
        if (!found) revert OracleNotReady();
        int192 thenCumulative = lower.cumulative;
        if (lower.time != targetTime) {
            thenCumulative += (upper.cumulative - lower.cumulative) * int192(uint192(targetTime - lower.time))
                / int192(uint192(upper.time - lower.time));
        }
        int192 change = nowCumulative - thenCumulative;
        meanTick = int24(change / 1800);
        if (change < 0 && change % 1800 != 0) meanTick--;
    }

    function quoteAtTick(int24 tick, uint128 amount, bool baseIs0) public pure returns (uint256) {
        uint160 sqrt = TickMath.getSqrtPriceAtTick(tick);
        if (sqrt <= type(uint128).max) {
            uint256 ratio = uint256(sqrt) * sqrt;
            return baseIs0 ? Math.mulDiv(ratio, amount, 1 << 192) : Math.mulDiv(1 << 192, amount, ratio);
        }
        uint256 ratio128 = Math.mulDiv(sqrt, sqrt, 1 << 64);
        return baseIs0 ? Math.mulDiv(ratio128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratio128);
    }
}
