// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity =0.8.0;

import "../interfaces/IAggregatorV3.sol";


contract Struct {

    struct Test {
        uint256 roundId;
    }

    struct TokenGlobal {
        address token;
        TokenRecord info;
        LatestRound latestRound;
    }

    struct LatestRound {
        address oracle;
        uint80 roundId;
        int256 price;
        uint256 timestamp;
    }

    struct HistoricalPricesParameters {
        uint256 lookbackInRound;
        uint256 lookbackInSec;
        uint256 timestamp;
    }

    struct SwapResult {
        uint256 amount;
        uint256 spread;
    }

    struct GBMEstimation {
        int256 mean;
        uint256 variance;
    }

    struct TokenRecord {
        uint256 balance;
        uint256 weight;
    }

    struct SwapParameters {
        uint256 amount;
        uint256 fee;
    }

    struct GBMParameters {
        uint256 z;
        uint256 horizon;
    }

}