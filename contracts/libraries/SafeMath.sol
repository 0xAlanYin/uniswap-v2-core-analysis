pragma solidity ^0.5.6;

// a library for performing overflow-safe math, courtesy of DappHub (https://github.com/dapphub/ds-math)
// 在 0.8.0 版本后，solidity 支持 check 机制，如果 overflow 了，会自动回滚
library SafeMath {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "ds-math-add-overflow");
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "ds-math-sub-underflow");
    }

    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "ds-math-mul-overflow");
    }
}
