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

pragma solidity =0.8.12;

import "./Const.sol";
import "./PoolToken.sol";
import "./Math.sol";

import "./Num.sol";
import "./structs/Struct.sol";


contract Pool is PoolToken {

    struct Record {
        bool bound;   // is token bound to pool
        uint8 index;   // private
        uint80 denorm;  // denormalized weight
        uint256 balance;
    }

    event LOG_SWAP(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256         tokenAmountIn,
        uint256         tokenAmountOut,
        uint256         spread
    );

    event LOG_JOIN(
        address indexed caller,
        address indexed tokenIn,
        uint256         tokenAmountIn
    );

    event LOG_EXIT(
        address indexed caller,
        address indexed tokenOut,
        uint256         tokenAmountOut
    );

    event LOG_CALL(
        bytes4  indexed sig,
        address indexed caller,
        bytes           data
    ) anonymous;

    modifier _logs_() {
        emit LOG_CALL(msg.sig, msg.sender, msg.data);
        _;
    }

    modifier _lock_() {
        require(!_mutex, "ERR_REENTRY");
        _mutex = true;
        _;
        _mutex = false;
    }

    modifier _viewlock_() {
        require(!_mutex, "ERR_REENTRY");
        _;
    }

    address[] private _tokens;
    mapping(address=>Record) private _records;

    bool private _mutex;
    // `finalize` sets `PUBLIC can SWAP`, `PUBLIC can JOIN`
    bool private _publicSwap; // true if PUBLIC can call SWAP functions
    uint80 private _totalWeight;
    address private _controller; // has CONTROL role
    
    bool private _finalized;
    address immutable private _factory;    // Factory address to push token exitFee to
    uint8 private priceStatisticsLookbackInRound;
    uint64 private dynamicCoverageFeesZ;

    // `setSwapFee` and `finalize` require CONTROL
    uint256 private _swapFee;
        
    mapping(address=>Price) private _prices;

    uint256 private dynamicCoverageFeesHorizon;
    uint256 private priceStatisticsLookbackInSec;

    constructor() {
        _controller = msg.sender;
        _factory = msg.sender;
        _swapFee = Const.MIN_FEE;
        _publicSwap = false;
        _finalized = false;
        priceStatisticsLookbackInRound = Const.BASE_LOOKBACK_IN_ROUND;
        priceStatisticsLookbackInSec = Const.BASE_LOOKBACK_IN_SEC;
        dynamicCoverageFeesZ = Const.BASE_Z;
        dynamicCoverageFeesHorizon = Const.BASE_HORIZON;
    }

    function isPublicSwap()
    external view
    returns (bool)
    {
        return _publicSwap;
    }

    function isFinalized()
    external view
    returns (bool)
    {
        return _finalized;
    }

    function isBound(address t)
    external view
    returns (bool)
    {
        return _records[t].bound;
    }

    function getNumTokens()
    external view
    returns (uint256)
    {
        return _tokens.length;
    }

    function getCurrentTokens()
    external view _viewlock_
    returns (address[] memory tokens)
    {
        return _tokens;
    }

    function getFinalTokens()
    external view
    _viewlock_
    returns (address[] memory tokens)
    {
        require(_finalized, "ERR_NOT_FINALIZED");
        return _tokens;
    }

    function getDenormalizedWeight(address token)
    external view
    _viewlock_
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _records[token].denorm;
    }

    function getTotalDenormalizedWeight()
    external view
    _viewlock_
    returns (uint256)
    {
        return _totalWeight;
    }

    function getNormalizedWeight(address token)
    external view
    _viewlock_
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        uint256 denorm = _records[token].denorm;
        return Num.bdiv(denorm, _totalWeight);
    }

    function getBalance(address token)
    external view
    _viewlock_
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _records[token].balance;
    }

    function getSwapFee()
    external view
    _viewlock_
    returns (uint256)
    {
        return _swapFee;
    }

    function getController()
    external view
    _viewlock_
    returns (address)
    {
        return _controller;
    }

    function setSwapFee(uint256 swapFee)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(swapFee >= Const.MIN_FEE, "ERR_MIN_FEE");
        require(swapFee <= Const.MAX_FEE, "ERR_MAX_FEE");
        require(swapFee >= 0, "ERR_FEE_SUP_0");
        require(swapFee <= Const.BONE, "ERR_FEE_INF_1");
        _swapFee = swapFee;
    }

    function setController(address manager)
    external
    _logs_
    _lock_
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(manager != address(0), "ERR_NULL_CONTROLLER");
        _controller = manager;
    }

    function setPublicSwap(bool public_)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        _publicSwap = public_;
    }

    /**
    * @notice Enables publicswap and finalizes the pool's tokens, price feeds, initial shares, balances and weights 
    */
    function finalize()
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_tokens.length >= Const.MIN_BOUND_TOKENS, "ERR_MIN_TOKENS");

        _finalized = true;
        _publicSwap = true;

        _mintPoolShare(Const.INIT_POOL_SUPPLY);
        _pushPoolShare(msg.sender, Const.INIT_POOL_SUPPLY);
    }

    // Absorb any tokens that have been sent to this contract into the pool
    function gulp(address token)
    external
    _logs_
    _lock_
    {
        require(_records[token].bound, "ERR_NOT_BOUND");
        _records[token].balance = IERC20(token).balanceOf(address(this));
    }

    /**
    * @notice Add liquidity to a pool
    * @dev The order of maxAmount of each token must be the same as the _tokens' addresses stored in the pool
    * @param poolAmountOut Amount of pool shares a LP wishes to receive
    * @param maxAmountsIn Maximum accepted token amount in
    */
    function joinPool(uint256 poolAmountOut, uint256[] calldata maxAmountsIn)
    external
    _logs_
    _lock_
    {
        require(_finalized, "ERR_NOT_FINALIZED");

        uint256 poolTotal = totalSupply();
        uint256 ratio = Num.bdiv(poolAmountOut, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        for (uint256 i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint256 bal = _records[t].balance;
            uint256 tokenAmountIn = Num.bmul(ratio, bal);
            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");
            _records[t].balance = _records[t].balance + tokenAmountIn;
            emit LOG_JOIN(msg.sender, t, tokenAmountIn);
            _pullUnderlying(t, msg.sender, tokenAmountIn);
        }
        _mintPoolShare(poolAmountOut);
        _pushPoolShare(msg.sender, poolAmountOut);
    }

    /**
    * @notice Remove liquidity from a pool
    * @dev The order of minAmount of each token must be the same as the _tokens' addresses stored in the pool
    * @param poolAmountIn Amount of pool shares a LP wishes to liquidate for tokens
    * @param minAmountsOut Minimum accepted token amount out
    */
    function exitPool(uint256 poolAmountIn, uint256[] calldata minAmountsOut)
    external
    _logs_
    _lock_
    {
        require(_finalized, "ERR_NOT_FINALIZED");

        uint256 poolTotal = totalSupply();
        uint256 exitFee = Num.bmul(poolAmountIn, Const.EXIT_FEE);
        uint256 pAiAfterExitFee = poolAmountIn - exitFee;
        uint256 ratio = Num.bdiv(pAiAfterExitFee, poolTotal);
        require(ratio != 0, "ERR_MATH_APPROX");

        _pullPoolShare(msg.sender, poolAmountIn);
        _pushPoolShare(_factory, exitFee);
        _burnPoolShare(pAiAfterExitFee);

        for (uint256 i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            uint256 bal = _records[t].balance;
            uint256 tokenAmountOut = Num.bmul(ratio, bal);
            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");
            _records[t].balance = _records[t].balance - tokenAmountOut;
            emit LOG_EXIT(msg.sender, t, tokenAmountOut);
            _pushUnderlying(t, msg.sender, tokenAmountOut);
        }

    }

    // ==
    // 'Underlying' token-manipulation functions make external calls but are NOT locked
    // You must `_lock_` or otherwise ensure reentry-safety

    function _pullUnderlying(address erc20, address from, uint256 amount)
    internal
    {
        bool xfer = IERC20(erc20).transferFrom(from, address(this), amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    function _pushUnderlying(address erc20, address to, uint256 amount)
    internal
    {
        bool xfer = IERC20(erc20).transfer(to, amount);
        require(xfer, "ERR_ERC20_FALSE");
    }

    function _pullPoolShare(address from, uint256 amount)
    internal
    {
        _pull(from, amount);
    }

    function _pushPoolShare(address to, uint256 amount)
    internal
    {
        _push(to, amount);
    }

    function _mintPoolShare(uint256 amount)
    internal
    {
        _mint(amount);
    }

    function _burnPoolShare(uint256 amount)
    internal
    {
        _burn(amount);
    }

    struct Price {
        IAggregatorV3 oracle;
        uint256 initialPrice;
    }

    event LOG_PRICE(
        address indexed token,
        address oracle,
        uint256 value
    ) anonymous;

    function setDynamicCoverageFeesZ(uint64 _dynamicCoverageFeesZ)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_dynamicCoverageFeesZ >= 0, "ERR_MIN_Z");
        require(_dynamicCoverageFeesZ <= Const.MAX_Z, "ERR_MAX_Z");
        dynamicCoverageFeesZ = _dynamicCoverageFeesZ;
    }

    function setDynamicCoverageFeesHorizon(uint256 _dynamicCoverageFeesHorizon)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_dynamicCoverageFeesHorizon >= Const.MIN_HORIZON, "ERR_MIN_HORIZON");
        require(_dynamicCoverageFeesHorizon <= Const.MAX_HORIZON, "ERR_MAX_HORIZON");
        dynamicCoverageFeesHorizon = _dynamicCoverageFeesHorizon;
    }

    function setPriceStatisticsLookbackInRound(uint8 _priceStatisticsLookbackInRound)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_priceStatisticsLookbackInRound >= Const.MIN_LOOKBACK_IN_ROUND, "ERR_MIN_LB_PERIODS");
        require(_priceStatisticsLookbackInRound <= Const.MAX_LOOKBACK_IN_ROUND, "ERR_MAX_LB_PERIODS");
        priceStatisticsLookbackInRound = _priceStatisticsLookbackInRound;
    }

    function setPriceStatisticsLookbackInSec(uint256 _priceStatisticsLookbackInSec)
    external
    _logs_
    _lock_
    {
        require(!_finalized, "ERR_IS_FINALIZED");
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_priceStatisticsLookbackInSec >= Const.MIN_LOOKBACK_IN_SEC, "ERR_MIN_LB_SECS");
        require(_priceStatisticsLookbackInSec <= Const.MAX_LOOKBACK_IN_SEC, "ERR_MAX_LB_SECS");
        priceStatisticsLookbackInSec = _priceStatisticsLookbackInSec;
    }

    function getCoverageParameters()
    external view
    _viewlock_
    returns (uint64, uint256, uint8, uint256)
    {
        return (
            dynamicCoverageFeesZ,
            dynamicCoverageFeesHorizon,
            priceStatisticsLookbackInRound,
            priceStatisticsLookbackInSec
        );
    }

    function getTokenPriceDecimals(address token)
    external view
    _viewlock_
    returns (uint8)
    {
        require(_records[token].bound, "ERR_NOT_BOUND");
        return _getTokenPriceDecimals(_prices[token].oracle);
    }

    function getTokenOraclePrice(address token)
    external view
    _viewlock_
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _getTokenCurrentPrice(_prices[token].oracle);
    }

    function getTokenOracleInitialPrice(address token)
    external view
    _viewlock_
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _prices[token].initialPrice;
    }

    function getTokenPriceOracle(address token)
    external view
    _viewlock_
    returns (address)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return address(_prices[token].oracle);
    }

    function getDenormalizedWeightMMM(address token)
    external view
    returns (uint256)
    {
        require(_records[token].bound, "ERR_NOT_BOUND");
        return _getAdjustedTokenWeight(token);
    }

    function getTotalDenormalizedWeightMMM()
    external view
    returns (uint256)
    {
        return _getTotalDenormalizedWeightMMM();
    }

    function getNormalizedWeightMMM(address token)
    external view
    returns (uint256)
    {

        require(_records[token].bound, "ERR_NOT_BOUND");
        return _getNormalizedWeightMMM(token);
    }

    function _getTotalDenormalizedWeightMMM()
    internal view
    _viewlock_
    returns (uint256)
    {
        uint256 _totalWeightMMM;
        for (uint256 i = 0; i < _tokens.length; i++) {
            _totalWeightMMM += _getAdjustedTokenWeight(_tokens[i]);
        }
        return _totalWeightMMM;
    }

    function _getNormalizedWeightMMM(address token)
    internal view
    _viewlock_
    returns (uint256)
    {

        return Num.bdiv(_getAdjustedTokenWeight(token), _getTotalDenormalizedWeightMMM());
    }

    /**
    * @notice Add a new token to the pool
    * @param token The token's address
    * @param balance The token's balance
    * @param denorm The token's weight
    * @param _priceFeedAddress The token's Chainlink price feed
    */
    function bindMMM(address token, uint256 balance, uint80 denorm, address _priceFeedAddress)
    external
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(!_records[token].bound, "ERR_IS_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");

        require(_tokens.length < Const.MAX_BOUND_TOKENS, "ERR_MAX_TOKENS");

        _records[token] = Record(
            {
                bound: true,
                index: uint8(_tokens.length),
                denorm: 0,    // balance and denorm will be validated
                balance: 0   // and set by `rebind`
            }
        );
        _tokens.push(token);
        _rebindMMM(token, balance, denorm, _priceFeedAddress);
    }

    /**
    * @notice Replace a binded token's balance, weight and price feed's address
    * @param token The token's address
    * @param balance The token's balance
    * @param denorm The token's weight
    * @param _priceFeedAddress The token's Chainlink price feed
    */
    function rebindMMM(address token, uint256 balance, uint80 denorm, address _priceFeedAddress)
    external
    {
        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_records[token].bound, "ERR_NOT_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");
        _rebindMMM(token, balance, denorm, _priceFeedAddress);
    }

    function _rebindMMM(address token, uint256 balance, uint80 denorm, address _priceFeedAddress)
    internal 
    _logs_
    _lock_
    {
        require(denorm >= Const.MIN_WEIGHT, "ERR_MIN_WEIGHT");
        require(denorm <= Const.MAX_WEIGHT, "ERR_MAX_WEIGHT");
        require(balance >= Const.MIN_BALANCE, "ERR_MIN_BALANCE");

        // Adjust the denorm and totalWeight
        uint80 oldWeight = _records[token].denorm;
        if (denorm > oldWeight) {
            _totalWeight = _totalWeight + (denorm - oldWeight);
            require(_totalWeight <= Const.MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");
        } else if (denorm < oldWeight) {
            _totalWeight = (_totalWeight - oldWeight) + denorm;
        }
        _records[token].denorm = denorm;

        // Adjust the balance record and actual token balance
        uint256 oldBalance = _records[token].balance;
        _records[token].balance = balance;
        if (balance > oldBalance) {
            _pullUnderlying(token, msg.sender, balance - oldBalance);
        } else if (balance < oldBalance) {
            // In this case liquidity is being withdrawn, so charge EXIT_FEE
            uint256 tokenBalanceWithdrawn = oldBalance - balance;
            uint256 tokenExitFee = Num.bmul(tokenBalanceWithdrawn, Const.EXIT_FEE);
            _pushUnderlying(token, msg.sender, tokenBalanceWithdrawn - tokenExitFee);
            _pushUnderlying(token, _factory, tokenExitFee);
        }

        // Add token price
        _prices[token] = Price(
            {
                oracle: IAggregatorV3(_priceFeedAddress),
                initialPrice: 0 // set right below
            }
        );
        _prices[token].initialPrice = _getTokenCurrentPrice(_prices[token].oracle);
        emit LOG_PRICE(token, address(_prices[token].oracle), _prices[token].initialPrice);
    }


    /**
    * @notice Remove a new token from the pool
    * @param token The token's address
    */
    function unbindMMM(address token)
    external
    _logs_
    _lock_
    {

        require(msg.sender == _controller, "ERR_NOT_CONTROLLER");
        require(_records[token].bound, "ERR_NOT_BOUND");
        require(!_finalized, "ERR_IS_FINALIZED");

        uint256 tokenBalance = _records[token].balance;
        uint256 tokenExitFee = Num.bmul(tokenBalance, Const.EXIT_FEE);

        _totalWeight = _totalWeight - _records[token].denorm;

        // Swap the token-to-unbind with the last token,
        // then delete the last token
        uint8 index = _records[token].index;
        uint256 last = _tokens.length - 1;
        _tokens[index] = _tokens[last];
        _records[_tokens[index]].index = index;
        _tokens.pop();
        delete _records[token];
        delete _prices[token];

        _pushUnderlying(token, msg.sender, tokenBalance - tokenExitFee);
        _pushUnderlying(token, _factory, tokenExitFee);

    }

    function _getSpotPriceMMMWithTimestamp(address tokenIn, address tokenOut, uint256 swapFee, uint256 timestamp)
    internal view _viewlock_
    returns (uint256 spotPrice)
    {
        require(_records[tokenIn].bound && _records[tokenOut].bound, "ERR_NOT_BOUND");

        Struct.TokenGlobal memory tokenGlobalIn = getTokenLatestInfo(tokenIn);
        Struct.TokenGlobal memory tokenGlobalOut = getTokenLatestInfo(tokenOut);
        
        Struct.GBMParameters memory gbmParameters = Struct.GBMParameters(dynamicCoverageFeesZ, dynamicCoverageFeesHorizon);
        Struct.HistoricalPricesParameters memory hpParameters = Struct.HistoricalPricesParameters(
            priceStatisticsLookbackInRound,
            priceStatisticsLookbackInSec,
            timestamp
        );

        return Math.calcSpotPriceMMM(
            tokenGlobalIn.info, tokenGlobalIn.latestRound,
            tokenGlobalOut.info, tokenGlobalOut.latestRound,
            getTokenRelativePrice(tokenGlobalIn.latestRound, tokenGlobalOut.latestRound),
            swapFee, gbmParameters,
            hpParameters
        );
    }

    function getSpotPriceMMM(address tokenIn, address tokenOut)
    external view
    returns (uint256 spotPrice)
    {
        return _getSpotPriceMMMWithTimestamp(tokenIn, tokenOut, _swapFee, block.timestamp);
    }

    function getSpotPriceSansFeeMMM(address tokenIn, address tokenOut)
    external view
    returns (uint256 spotPrice)
    {
        return _getSpotPriceMMMWithTimestamp(tokenIn, tokenOut, 0, block.timestamp);
    }

    function swapExactAmountInMMM(
        address tokenIn,
        uint256 tokenAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 maxPrice
    )
    external
    returns (uint256 tokenAmountOut, uint256 spotPriceAfter)
    {
        return _swapExactAmountInMMMWithTimestamp(
            tokenIn,
            tokenAmountIn,
            tokenOut,
            minAmountOut,
            maxPrice,
            block.timestamp
        );
    }

    function _swapExactAmountInMMMWithTimestamp(
        address tokenIn,
        uint256 tokenAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 maxPrice,
        uint256 timestamp
    )
    internal
    _logs_
    _lock_
    returns (uint256 tokenAmountOut, uint256 spotPriceAfter)
    {

        require(_records[tokenIn].bound && _records[tokenOut].bound, "ERR_NOT_BOUND");
        require(_publicSwap, "ERR_SWAP_NOT_PUBLIC");

        require(tokenAmountIn <= Num.bmul(_records[tokenIn].balance, Const.MAX_IN_RATIO), "ERR_MAX_IN_RATIO");

        Struct.TokenGlobal memory tokenGlobalIn = getTokenLatestInfo(tokenIn);
        Struct.TokenGlobal memory tokenGlobalOut = getTokenLatestInfo(tokenOut);

        uint256 spotPriceBefore = Math.calcSpotPrice(
            tokenGlobalIn.info.balance,
            tokenGlobalIn.info.weight,
            tokenGlobalOut.info.balance,
            tokenGlobalOut.info.weight,
            _swapFee
        );
        require(spotPriceBefore <= maxPrice, "ERR_BAD_LIMIT_PRICE");

        Struct.SwapResult memory swapResult = _getAmountOutGivenInMMMWithTimestamp(
            tokenGlobalIn,
            tokenGlobalOut,
            tokenAmountIn,
            timestamp
        );
        require(swapResult.amount >= minAmountOut, "ERR_LIMIT_OUT");

        _records[address(tokenIn)].balance = tokenGlobalIn.info.balance + tokenAmountIn;
        _records[address(tokenOut)].balance = tokenGlobalOut.info.balance - swapResult.amount;

        spotPriceAfter = Math.calcSpotPrice(
            _records[address(tokenIn)].balance,
            tokenGlobalIn.info.weight,
            _records[address(tokenOut)].balance,
            tokenGlobalOut.info.weight,
            _swapFee
        );
        require(spotPriceAfter >= spotPriceBefore, "ERR_MATH_APPROX");
        require(spotPriceAfter <= maxPrice, "ERR_LIMIT_PRICE");
        require(spotPriceBefore <= Num.bdiv(tokenAmountIn, swapResult.amount), "ERR_MATH_APPROX");

        emit LOG_SWAP(msg.sender, tokenIn, tokenOut, tokenAmountIn, swapResult.amount, swapResult.spread);

        _pullUnderlying(tokenIn, msg.sender, tokenAmountIn);
        _pushUnderlying(tokenOut, msg.sender, swapResult.amount);

        return (tokenAmountOut = swapResult.amount, spotPriceAfter);
    }

    function swapExactAmountOutMMM(
        address tokenIn,
        uint256 maxAmountIn,
        address tokenOut,
        uint256 tokenAmountOut,
        uint256 maxPrice
    )
    external
    returns (uint256 tokenAmountIn, uint256 spotPriceAfter)
    {
        return _swapExactAmountOutMMMWithTimestamp(
            tokenIn,
            maxAmountIn,
            tokenOut,
            tokenAmountOut,
            maxPrice,
            block.timestamp
        );
    }

    function getAmountOutGivenInMMM(
        address tokenIn,
        uint256 tokenAmountIn,
        address tokenOut
    )
    external view
    returns (uint256 tokenAmountOut)
    {

        Struct.TokenGlobal memory tokenGlobalIn = getTokenLatestInfo(tokenIn);
        Struct.TokenGlobal memory tokenGlobalOut = getTokenLatestInfo(tokenOut);

        Struct.SwapResult memory swapResult = _getAmountOutGivenInMMMWithTimestamp(
            tokenGlobalIn,
            tokenGlobalOut,
            tokenAmountIn,
            block.timestamp
        );

        return tokenAmountOut = swapResult.amount;
    }

    function _getAmountOutGivenInMMMWithTimestamp(
        Struct.TokenGlobal memory tokenGlobalIn,
        Struct.TokenGlobal memory tokenGlobalOut,
        uint256 tokenAmountIn,
        uint256 timestamp
    )
    internal view
    returns (Struct.SwapResult memory)
    {

        require(tokenAmountIn <= Num.bmul(tokenGlobalIn.info.balance, Const.MAX_IN_RATIO), "ERR_MAX_IN_RATIO");

        Struct.SwapParameters memory swapParameters = Struct.SwapParameters(tokenAmountIn, _swapFee);
        Struct.GBMParameters memory gbmParameters = Struct.GBMParameters(dynamicCoverageFeesZ, dynamicCoverageFeesHorizon);
        Struct.HistoricalPricesParameters memory hpParameters = Struct.HistoricalPricesParameters(
            priceStatisticsLookbackInRound,
            priceStatisticsLookbackInSec,
            timestamp
        );

        return Math.calcOutGivenInMMM(
            tokenGlobalIn.info,
            tokenGlobalIn.latestRound,
            tokenGlobalOut.info,
            tokenGlobalOut.latestRound,
            getTokenRelativePrice(tokenGlobalIn.latestRound, tokenGlobalOut.latestRound),
            swapParameters,
            gbmParameters,
            hpParameters
        );

    }

    function _swapExactAmountOutMMMWithTimestamp(
        address tokenIn,
        uint256 maxAmountIn,
        address tokenOut,
        uint256 tokenAmountOut,
        uint256 maxPrice,
        uint256 timestamp
    )
    internal
    _logs_
    _lock_
    returns (uint256 tokenAmountIn, uint256 spotPriceAfter)
    {

        require(_records[tokenIn].bound, "ERR_NOT_BOUND");
        require(_records[tokenOut].bound, "ERR_NOT_BOUND");
        require(_publicSwap, "ERR_SWAP_NOT_PUBLIC");

        require(tokenAmountOut <= Num.bmul(_records[tokenOut].balance, Const.MAX_OUT_RATIO), "ERR_MAX_OUT_RATIO");

        Struct.TokenGlobal memory tokenGlobalIn = getTokenLatestInfo(tokenIn);
        Struct.TokenGlobal memory tokenGlobalOut = getTokenLatestInfo(tokenOut);
    
        // TODO: Re-check the necessity to calculate spotPriceBefore (and the conditions used in it later)
        uint256 spotPriceBefore = Math.calcSpotPrice(
            tokenGlobalIn.info.balance,
            tokenGlobalIn.info.weight,
            tokenGlobalOut.info.balance,
            tokenGlobalOut.info.weight,
            _swapFee
        );
        
        require(spotPriceBefore <= maxPrice, "ERR_BAD_LIMIT_PRICE");

        Struct.SwapResult memory swapResult = _getAmountInGivenOutMMMWithTimestamp(
            tokenGlobalIn,
            tokenGlobalOut,
            tokenAmountOut,
            timestamp
        );

        require(swapResult.amount <= maxAmountIn, "ERR_LIMIT_IN");

        _records[address(tokenIn)].balance = tokenGlobalIn.info.balance + swapResult.amount;
        _records[address(tokenOut)].balance = tokenGlobalOut.info.balance - tokenAmountOut;

        spotPriceAfter = Math.calcSpotPrice(
            _records[address(tokenIn)].balance,
            tokenGlobalIn.info.weight,
            _records[address(tokenOut)].balance,
            tokenGlobalOut.info.weight,
            _swapFee
        );
        require(spotPriceAfter >= spotPriceBefore, "ERR_MATH_APPROX");
        require(spotPriceAfter <= maxPrice, "ERR_LIMIT_PRICE");
        require(spotPriceBefore <= Num.bdiv(swapResult.amount, tokenAmountOut), "ERR_MATH_APPROX");

        emit LOG_SWAP(msg.sender, tokenIn, tokenOut, swapResult.amount, tokenAmountOut, swapResult.spread);

        _pullUnderlying(tokenIn, msg.sender, swapResult.amount);
        _pushUnderlying(tokenOut, msg.sender, tokenAmountOut);

        return (tokenAmountIn = swapResult.amount, spotPriceAfter);
    }

    function getAmountInGivenOutMMM(
        address tokenIn,
        address tokenOut,
        uint256 tokenAmountOut
    )
    public view
    returns (uint256 tokenAmountIn)
    {

        Struct.TokenGlobal memory tokenGlobalIn = getTokenLatestInfo(tokenIn);
        Struct.TokenGlobal memory tokenGlobalOut = getTokenLatestInfo(tokenOut);

        Struct.SwapResult memory swapResult = _getAmountInGivenOutMMMWithTimestamp(
            tokenGlobalIn,
            tokenGlobalOut,
            tokenAmountOut,
            block.timestamp
        );

        return tokenAmountIn = swapResult.amount;
    }

    function _getAmountInGivenOutMMMWithTimestamp(
        Struct.TokenGlobal memory tokenGlobalIn,
        Struct.TokenGlobal memory tokenGlobalOut,
        uint256 tokenAmountOut,
        uint256 timestamp
    )
    internal view
    returns (Struct.SwapResult memory)
    {
        Struct.SwapParameters memory swapParameters = Struct.SwapParameters(tokenAmountOut, _swapFee);
        Struct.GBMParameters memory gbmParameters = Struct.GBMParameters(dynamicCoverageFeesZ, dynamicCoverageFeesHorizon);
        Struct.HistoricalPricesParameters memory hpParameters = Struct.HistoricalPricesParameters(
            priceStatisticsLookbackInRound,
            priceStatisticsLookbackInSec,
            timestamp
        );

        return Math.calcInGivenOutMMM(
            tokenGlobalIn.info,
            tokenGlobalIn.latestRound,
            tokenGlobalOut.info,
            tokenGlobalOut.latestRound,
            getTokenRelativePrice(tokenGlobalOut.latestRound, tokenGlobalIn.latestRound),
            swapParameters,
            gbmParameters,
            hpParameters
        );

    }

    /**
    * @notice Compute the token historical performance since pool's inception
    * @param initialPrice The token's initial price
    * @param latestPrice The token's latest price
    * @return tokenGlobal The token historical performance since pool's inception
    */
    function _getTokenPerformance(uint256 initialPrice, uint256 latestPrice)
    internal pure returns (uint256) {
        return Num.bdiv(
            latestPrice,
            initialPrice
        );
    }

    function _getAdjustedTokenWeight(address token)
    internal view returns (uint256) {
        // we adjust the token's target weight (in value) based on its appreciation since the inception of the pool.
        return Num.bmul(
            _records[token].denorm,
            _getTokenPerformance(
                _prices[token].initialPrice,
                _getTokenCurrentPrice(_prices[token].oracle)
            )
        );
    }

    /**
    * @notice Retrieves the given token's latest oracle data.
    * @dev We get:
    * - latest round Id
    * - latest price
    * - latest round timestamp
    * - token historical performance since pool's inception
    * @param token The token's address
    * @return tokenGlobal The latest tokenIn oracle data
    */
    function getTokenLatestInfo(address token)
    internal view returns (Struct.TokenGlobal memory tokenGlobal) {
        Record memory record = _records[token];
        Price memory price = _prices[token];
        (uint80 latestRoundId, int256 latestPrice, , uint256 latestTimestamp,) = price.oracle.latestRoundData();
        Struct.TokenRecord memory info = Struct.TokenRecord(
            record.balance,
            // we adjust the token's target weight (in value) based on its appreciation since the inception of the pool.
            Num.bmul(
                record.denorm,
                _getTokenPerformance(
                    price.initialPrice,
                    _toUInt256Unsafe(latestPrice) // we consider the token price to be > 0
                )
            )
        );
        Struct.LatestRound memory latestRound = Struct.LatestRound(address(price.oracle), latestRoundId, latestPrice, latestTimestamp);
        return (
            tokenGlobal = Struct.TokenGlobal(
                info,
                latestRound
            )
        );
    }

    /**
    * @notice Retrieves the latest price from the given oracle price feed
    * @dev We consider the token price to be > 0
    * @param priceFeed The price feed of interest
    * @return The latest price
    */
    function _getTokenCurrentPrice(IAggregatorV3 priceFeed) internal view returns (uint256) {
        (, int256 price, , ,) = priceFeed.latestRoundData();
        return _toUInt256Unsafe(price);  // we consider the token price to be > 0
    }

    function _getTokenPriceDecimals(IAggregatorV3 priceFeed) internal view returns (uint8) {
        return priceFeed.decimals();
    }

    function _toUInt256Unsafe(int256 value) internal pure returns (uint256) {
        if (value <= 0) {
            return uint256(0);
        }
        return uint256(value);
    }

    /**
    * @notice Computes the price of token 2 in terms token 1
    * @param latestRound_1 The latest oracle data for token 1
    * @param latestRound_2 The latest oracle data for token 2
    * @return The price of token 2 in terms of token 1
    */
    function getTokenRelativePrice(
        Struct.LatestRound memory latestRound_1, Struct.LatestRound memory latestRound_2
    )
    internal
    view
    returns (uint256) {
        uint8 decimal_1 = IAggregatorV3(latestRound_1.oracle).decimals();
        uint8 decimal_2 = IAggregatorV3(latestRound_2.oracle).decimals();
        // we consider tokens price to be > 0
        uint256 rawDiv = Num.bdiv(_toUInt256Unsafe(latestRound_2.price), _toUInt256Unsafe(latestRound_1.price));
        if (decimal_1 == decimal_2) {
            return rawDiv;
        } else if (decimal_1 > decimal_2) {
            return Num.bmul(
                rawDiv,
                10**(decimal_1 - decimal_2)*Const.BONE
            );
        } else {
            return Num.bdiv(
                rawDiv,
                10**(decimal_2 - decimal_1)*Const.BONE
            );
        }
    }

}