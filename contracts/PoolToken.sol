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

import "./Num.sol";
import "./interfaces/IERC20.sol";

// Highly opinionated token implementation

contract TokenBase {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    using Num for uint256;

    mapping(address => uint256)                   internal _balance;
    mapping(address => mapping(address=>uint256)) internal _allowance;
    uint256 internal _totalSupply;

    function _mint(uint256 amt) internal {
        _balance[address(this)] = Num.badd(_balance[address(this)], amt);
        _totalSupply = Num.badd(_totalSupply, amt);
        emit Transfer(address(0), address(this), amt);
    }

    function _burn(uint256 amt) internal {
        require(_balance[address(this)] >= amt, "ERR_INSUFFICIENT_BAL");
        _balance[address(this)] = Num.bsub(_balance[address(this)], amt);
        _totalSupply = Num.bsub(_totalSupply, amt);
        emit Transfer(address(this), address(0), amt);
    }

    function _move(address src, address dst, uint256 amt) internal {
        require(_balance[src] >= amt, "ERR_INSUFFICIENT_BAL");
        require(dst != address(0), "ERR_NULL_ADDRESS");
        _balance[src] = Num.bsub(_balance[src], amt);
        _balance[dst] = Num.badd(_balance[dst], amt);
        emit Transfer(src, dst, amt);
    }

    function _push(address to, uint256 amt) internal {
        _move(address(this), to, amt);
    }

    function _pull(address from, uint256 amt) internal {
        _move(from, address(this), amt);
    }
}

contract PoolToken is TokenBase, IERC20 {

    string  private _name     = "Swaap Pool Token";
    string  private _symbol   = "SPT";
    uint8   private _decimals = 18;

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns(uint8) {
        return _decimals;
    }

    function allowance(address src, address dst) external view override returns (uint256) {
        return _allowance[src][dst];
    }

    function balanceOf(address whom) external view override returns (uint256) {
        return _balance[whom];
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function approve(address dst, uint256 amt) external override returns (bool) {
        _allowance[msg.sender][dst] = amt;
        emit Approval(msg.sender, dst, amt);
        return true;
    }

    function increaseApproval(address dst, uint256 amt) external returns (bool) {
        _allowance[msg.sender][dst] = Num.badd(_allowance[msg.sender][dst], amt);
        emit Approval(msg.sender, dst, _allowance[msg.sender][dst]);
        return true;
    }

    function decreaseApproval(address dst, uint256 amt) external returns (bool) {
        uint256 oldValue = _allowance[msg.sender][dst];
        if (amt > oldValue) {
            _allowance[msg.sender][dst] = 0;
        } else {
            _allowance[msg.sender][dst] = Num.bsub(oldValue, amt);
        }
        emit Approval(msg.sender, dst, _allowance[msg.sender][dst]);
        return true;
    }

    function transfer(address dst, uint256 amt) external override returns (bool) {
        _move(msg.sender, dst, amt);
        return true;
    }

    function transferFrom(address src, address dst, uint256 amt) external override returns (bool) {
        require(msg.sender == src || amt <= _allowance[src][msg.sender], "ERR_POOL_TOKEN_BAD_CALLER");
        _move(src, dst, amt);
        if (msg.sender != src && _allowance[src][msg.sender] != type(uint256).max) {
            _allowance[src][msg.sender] = Num.bsub(_allowance[src][msg.sender], amt);
            emit Approval(msg.sender, dst, _allowance[src][msg.sender]);
        }
        return true;
    }
}