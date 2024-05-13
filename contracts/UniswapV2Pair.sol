pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint256; // 引入两个库
    using UQ112x112 for uint224;

    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3; // 最小流动性（详细见白皮书）
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)"))); //
    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves // 储备量 0
    uint112 private reserve1; // uses single storage slot, accessible via getReserves // 储备量 1
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves // 上一次更新的时间戳

    uint256 public price0CumulativeLast; // 价格0最后累积值【这两个值在本合约中不会使用，主要用于 Uniswap 的价格预言机，示例代码可以参见 https://github.com/Uniswap/v2-periphery/blob/master/contracts/examples/ExampleOracleSimple.sol】
    uint256 public price1CumulativeLast; // 价格1最后累积值
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint256 private unlocked = 1;

    /**
     * @notice 修饰符，锁定运行防止重入攻击
     */
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender; // factory地址为合约的部署者，即工厂地址
    }

    // called once by the factory at time of deployment
    /**
     * @notice 初始化方法，在部署时由工厂合约调用一次
     * @param _token0 token0
     * @param _token1 token1
     */
    function initialize(address _token0, address _token1) external {
        // 确认调用者为工厂
        require(msg.sender == factory, "UniswapV2: FORBIDDEN"); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @notice 获取储备量
     * @return _reserve0 储备量0
     * @return _reserve1 储备量1
     * @return _blockTimestampLast 时间戳
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // this low-level function should be called from a contract which performs important safety checks
    /**
     * @notice 铸造流动性： 在添加储备量的时候使用（无论是第一次还是后面使用）
     * @param to 铸造流动性的地址
     */
    function mint(address to) external lock returns (uint256 liquidity) {
        // 获取储备量 0 和储备量 1
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 获取当前合约在 token0 合约内的余额
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        // 获取当前合约在 token1 合约内的余额
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        // 计算 amount0 = 余额0 - 储备量 0 ==> 即本次 mint 带来的值（第一次来 mint 时_reserve0值为0，amount0就等于全部的余额）
        uint256 amount0 = balance0.sub(_reserve0);
        // 计算 amount1 = 余额1 - 储备量 1
        uint256 amount1 = balance1.sub(_reserve1);

        // 返回是否收取铸造费的开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        // 如果总供应量为 0
        if (_totalSupply == 0) {
            // 流动性 = (数量0 * 数量1) - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 在总量为 0 的初始状态下，永久锁定最低的流动性（即把最小流动性mint给 0 地址）
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            // 流动性 = 取（amount0 *_totalSupply/_reserve0）和 (amount1*_totalSupply/_reserve1) 的最小值
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        // 确保流动性>0
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        // 铸造流动性给 to 地址
        _mint(to, liquidity);

        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 如果收税开启，则更新 k 值。k值 = 储备量0 * 储备量1 ==> 自动乘积做市商 k = x * y
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        // 触发 Mint 事件
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000 ** 2),
                "UniswapV2: K"
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        // 确认余额0和余额1小于等于最大的 uint112 值（因为输入参数是 uint256 类型，必须做这个检查）
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), "UniswapV2: OVERFLOW");

        // 将区块时间戳转换为 uint32 类型
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);

        // 计算时间流逝量
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        // overflow is desired
        // 如果时间流逝量大于 0 并且储备量 0 和储备量 1 都不为 0，则会更新价格累积值
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // 价格0的最后累计 += 储备量1 * 2**12 / 储备量0 * 时间流逝量
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            // 价格1的最后累计 += 储备量0 * 2**12 / 储备量1 * 时间流逝量
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        // 余额0，1赋值给储备量0，1
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        // 更新最后一次的时间戳
        blockTimestampLast = blockTimestamp;
        // 发送同步事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    /**
     * @notice 本函数的计算公式需要结合白皮书中的公式理解（不建议只看代码，不容易明白来源）
     * @param _reserve0 储备量0
     * @param _reserve1 储备量1
     * @return feeOn 是否收税（收税开发是在工厂合约中设置的，默认初始是不开启的）
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 查询工厂合约的 feeTo 地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // 如果 feeTo 地址不为 0 地址，则 feeOn 为 true, 代表启用了收税
        feeOn = feeTo != address(0);
        // 定义 k 值
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            // 如果 k 值不等于 0，进一步计算
            if (_kLast != 0) {
                // 计算 （_reserve0*_reserve1）的平方根
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
                // 计算 k 值的平方根
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    // 分子 = erc20总量 * (rootK - rootKLast)
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    // 分母 = rootK * 5 + rootKLast
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    // 流动性 = 分子 / 分母
                    uint256 liquidity = numerator / denominator;
                    // 如果流动性大于 0，将流动性铸造给 feeTo 地址(对应白皮书里项目方收取到了 0.05% 的收取费)
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapV2: TRANSFER_FAILED");
    }
}
