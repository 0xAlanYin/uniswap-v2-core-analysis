pragma solidity ^0.5.6;

import "../interfaces/IUniswapV2Pair.sol";
import "../libraries/FixedPoint.sol";

import "../libraries/UniswapV2OracleLibrary.sol";
import "../libraries/UniswapV2Library.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract ExampleOracleSimple {
    using FixedPoint for *;

    uint256 public constant PERIOD = 24 hours;

    IUniswapV2Pair pair;
    address public token0;
    address public token1;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(address factory, address tokenA, address tokenB) public {
        // 获取交易对合约地址
        IUniswapV2Pair _pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, tokenA, tokenB));
        pair = _pair;
        token0 = _pair.token0();
        token1 = _pair.token1();
        price0CumulativeLast = _pair.price0CumulativeLast(); // fetch the current accumulated price value (1 / 0)
        price1CumulativeLast = _pair.price1CumulativeLast(); // fetch the current accumulated price value (0 / 1)
        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();
        require(reserve0 != 0 && reserve1 != 0, "ExampleOracleSimple: NO_RESERVES"); // ensure that there's liquidity in the pair
    }

    function update() external {
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) =
            UniswapV2OracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // ensure that at least one full period has passed since the last update
        // 必须按照预先设置的时间间隔更新（此处可以根据不同的需求自行调整间隔）
        require(timeElapsed >= PERIOD, "ExampleOracleSimple: PERIOD_NOT_ELAPSED");

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;
    }

    // note this will always return 0 before update has been called successfully for the first time.
    // 计算金额数：根据记录的平均价格计算给定数量的代币（token）相对于另一个代币中的价值
    // 例如  ETH/DAI 交易对， price0Average: 0.02 DAI/ETH（即每个 ETH 值 0.02 DAI），price1Average: 50 ETH/DAI（即每个 DAI 值 50 ETH）
    function consult(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, "ExampleOracleSimple: INVALID_TOKEN");
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }
}