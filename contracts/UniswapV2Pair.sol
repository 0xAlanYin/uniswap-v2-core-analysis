pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Pair.sol";
import "./UniswapV2ERC20.sol";
import "./libraries/Math.sol";
import "./libraries/UQ112x112.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Callee.sol";

//Uniswap配对合约
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;

    //最小流动性 = 1000
    uint256 public constant MINIMUM_LIQUIDITY = 10 ** 3;
    //SELECTOR常量值为'transfer(address,uint256)'字符串哈希值的前4位16进制数字
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));

    address public factory; //工厂地址
    address public token0; //token0地址
    address public token1; //token1地址

    // 小技巧：下面 3 个值存储在一个 slot 里，节省了存储
    uint112 private reserve0; // 储备量0
    uint112 private reserve1; // 储备量1
    uint32 private blockTimestampLast; // 更新储备量的最后时间戳

    //价格0最后累计
    uint256 public price0CumulativeLast;
    //价格1最后累计
    uint256 public price1CumulativeLast;

    //在最近一次流动性事件之后的K值
    //储备量0*储备量1，自最近一次流动性事件发生后的 k 值
    uint256 public kLast;
    //锁定变量,防止重入攻击
    uint256 private unlocked = 1;

    //事件:铸造
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    //事件:销毁
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    /**
     * @dev 事件:交换
     * @param sender 发送者
     * @param amount0In 输入金额0
     * @param amount1In 输入金额1
     * @param amount0Out 输出金额0
     * @param amount1Out 输出金额1
     * @param to to地址
     */
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    /**
     * @dev 事件:同步
     * @param reserve0 储备量0
     * @param reserve1 储备量1
     */
    event Sync(uint112 reserve0, uint112 reserve1);

    /**
     * @dev 构造函数
     */
    constructor() public {
        //factory地址为合约布署者
        factory = msg.sender;
    }

    /**
     * @param _token0 token0
     * @param _token1 token1
     * @dev 初始化方法,在使用 create2 部署后，由工厂调用一次
     */
    function initialize(address _token0, address _token1) external {
        //确认调用者为工厂地址
        require(msg.sender == factory, "UniswapV2: FORBIDDEN");
        token0 = _token0;
        token1 = _token1;
    }

    /**
     * @dev 修饰符:锁定运行防止重入
     */
    modifier lock() {
        require(unlocked == 1, "UniswapV2: LOCKED");
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**
     * @return _reserve0 储备量0
     * @return _reserve1 储备量1
     * @return _blockTimestampLast 时间戳
     * @dev 获取储备
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
     * @param token token地址
     * @param to    to地址
     * @param value 数额
     * @dev 私有安全发送
     */
    function _safeTransfer(address token, address to, uint256 value) private {
        //调用token合约地址的低级transfer方法
        //solium-disable-next-line
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        //确认返回值为true并且返回的data长度为0或者解码后为true
        require(success && (data.length == 0 || abi.decode(data, (bool))), "UniswapV2: TRANSFER_FAILED");
    }

    /**
     * @param balance0 余额0
     * @param balance1  余额1
     * @param _reserve0 储备0
     * @param _reserve1 储备1
     * @dev 更新储量，并在每个区块的第一次调用时更新价格累加器
     */
    function _update(uint256 balance0, uint256 balance1, uint112 _reserve0, uint112 _reserve1) private {
        //确认余额0和余额1小于等于最大的uint112
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), "UniswapV2: OVERFLOW");
        //区块时间戳,将时间戳转换为uint32
        //solium-disable-next-line
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        //计算时间流逝
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //如果时间流逝>0 并且 储备量0,1不等于0
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            //价格0最后累计 += 储备量1 * 2**112 / 储备量0 * 时间流逝
            //solium-disable-next-line
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            //价格1最后累计 += 储备量0 * 2**112 / 储备量1 * 时间流逝
            //solium-disable-next-line
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //余额0,1放入储备量0,1
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        //更新最后时间戳
        blockTimestampLast = blockTimestamp;
        //触发同步事件
        emit Sync(reserve0, reserve1);
    }

    /**
     * @param _reserve0 储备0
     * @param _reserve1 储备1
     * @return feeOn
     * @dev 如果收费，铸造流动性相当于1/6的增长sqrt（k）
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //查询工厂合约的feeTo变量值
        address feeTo = IUniswapV2Factory(factory).feeTo();
        //如果feeTo不等于0地址（说明设置了手续费收取）,feeOn等于true否则为false
        feeOn = feeTo != address(0);
        //定义k值
        uint256 _kLast = kLast; // gas savings
        //如果feeOn等于true
        if (feeOn) {
            //如果k值不等于0
            if (_kLast != 0) {
                //计算(_reserve0*_reserve1)的平方根: k 开根号
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
                //计算k值的平方根
                uint256 rootKLast = Math.sqrt(_kLast);
                //如果rootK>rootKLast
                if (rootK > rootKLast) {
                    //分子 = erc20总量 * (rootK - rootKLast)
                    // 对应白皮书中的公式（7） 分子 = (sqrt(k2) - sqrt(k1)) * s1
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    //分母 = rootK * 5 + rootKLast
                    // 对应白皮书中的公式（7） 分母 = 5*sqrt(k2) - sqrt(k1)
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    //流动性 = 分子 / 分母
                    uint256 liquidity = numerator / denominator;
                    // 如果流动性 > 0 将流动性铸造给feeTo地址
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
            //否则如果_kLast不等于0
        } else if (_kLast != 0) {
            //k值=0
            kLast = 0;
        }
    }

    /**
     * @param to to地址
     * @return liquidity 流动性数量
     * @dev 铸造方法
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        //获取`储备量0`,`储备量1`：这个值是之前交易中积累的
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //获取当前合约在token0合约内的余额
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        //获取当前合约在token1合约内的余额：这个余额包含了储备量 + 最近因为添加流动性而增加的代币数量
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        //amount0 = 余额0 - 储备0
        uint256 amount0 = balance0.sub(_reserve0);
        //amount1 = 余额1 - 储备1
        uint256 amount1 = balance1.sub(_reserve1);

        //返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //获取totalSupply,必须在此处定义，因为totalSupply的值可能在mintFee中被更新了
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //如果_totalSupply等于0，说明是交易对第一次添加流动性
        if (_totalSupply == 0) {
            //流动性 = (数量0 * 数量1)的平方根 - 最小流动性1000
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //在总量为0的初始状态,永久锁定最低流动性
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            //流动性 = 取 (amount0 * _totalSupply / _reserve0) 和 (amount1 * _totalSupply / _reserve1) 的更小值
            // amount0 * _totalSupply / _reserve0：表示新增的 token0 数量在总供应量中的比例。用于计算出新增的 token0 对应的流动性代币数量。
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
            // 前置知识：添加流动性时，需要确保新加入的流动性与现有流动性比例相同，以保持池子的平衡
            // 为了确保池子的平衡，实际分配的流动性代币数量需要取这两个计算结果的最小值。原因如下：
            //确保了在添加流动性时，用户获得的流动性代币数量与他们添加的 token0 和 token1 数量成比例，并且不会超出实际添加量的任何一种代币。
            //通过取最小值，保持了流动性池的平衡，防止了单一代币的过度分配。
        }
        //确认流动性 > 0
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        //铸造流动性给to地址
        _mint(to, liquidity);

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //如果铸造费开关为true, k值 = 储备0 * 储备1
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        //触发铸造事件
        emit Mint(msg.sender, amount0, amount1);
    }

    /**
     * @param to to地址
     * @return amount0
     * @return amount1
     * @dev 销毁方法
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        //获取`储备量0`,`储备量1`
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //带入变量
        address _token0 = token0; // gas savings：因为本函数中需要多次用到 token0，使用临时变量无需反复从存储中加载，节省 gas 费
        address _token1 = token1; // gas savings
        //获取当前合约在token0合约内的余额
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        //获取当前合约在token1合约内的余额
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        // 从当前合约的balanceOf映射中获取当前合约自身的流动性数量
        //这里这么做的原因是：移除流动性时，用户先把 LPToken 转给 Pair 合约，再销毁转给 Pair 合约的 LPToken，然后给用户转相应的 token0 和 token1
        uint256 liquidity = balanceOf[address(this)];

        //返回铸造费开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        //获取totalSupply,必须在此处定义，因为totalSupply可以在mintFee中更新
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //amount0 = 流动性数量 * 余额0 / totalSupply   使用余额确保按比例分配
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        //amount1 = 流动性数量 * 余额1 / totalSupply   使用余额确保按比例分配
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        //确认amount0和amount1都大于0
        require(amount0 > 0 && amount1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        //销毁当前合约内的流动性数量
        _burn(address(this), liquidity);
        //将amount0数量的_token0发送给to地址
        _safeTransfer(_token0, to, amount0);
        //将amount1数量的_token1发送给to地址
        _safeTransfer(_token1, to, amount1);
        //更新balance0
        balance0 = IERC20(_token0).balanceOf(address(this));
        //更新balance1
        balance1 = IERC20(_token1).balanceOf(address(this));

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //如果铸造费开关为true, k值 = 储备0 * 储备1
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        //触发销毁事件
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
     * @param amount0Out 输出数额0
     * @param amount1Out 输出数额1
     * @param to    to地址
     * @param data  用于回调的数据
     * @dev 交换方法
     * @notice 应该从执行重要安全检查的合同中调用此低级功能
     */
    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        //确认amount0Out和amount1Out有一个大于0（因为 swap 是用一个币种换另一个币种 ，所以是有一个 amountOut 为 0）
        require(amount0Out > 0 || amount1Out > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        //获取`储备量0`,`储备量1`
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //确认`输出数量0 ,1` < `储备量0,1`，不能超量交换
        require(amount0Out < _reserve0 && amount1Out < _reserve1, "UniswapV2: INSUFFICIENT_LIQUIDITY");

        //初始化变量
        uint256 balance0;
        uint256 balance1;
        {
            //标记_token{0,1}的作用域，避免堆栈太深的错误
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;

            //确认to地址不等于_token0和_token1
            require(to != _token0 && to != _token1, "UniswapV2: INVALID_TO");
            //如果`输出数量0` > 0 安全发送`输出数量0`的token0到to地址
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            //如果`输出数量1` > 0 安全发送`输出数量1`的token1到to地址
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            //如果data的长度大于0 调用to地址的接口
            if (data.length > 0) {
                // 这里的 to 必须是合约地址，并且要实现 IUniswapV2Callee 接口：这里的 msg.sender 是路由合约
                // 其实这一步就是闪电贷的功能： address to 实现了 IUniswapV2Callee 接口
                IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            }
            //`余额0,1` = 当前合约在`token0,1`合约内的余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        //如果 余额0 > 储备0 - amount0Out 则 amount0In = 余额0 - (储备0 - amount0Out) 否则 amount0In = 0
        // 简单而言：这里是利用 储备量-输出量(_reserve0 - amount0Out)，从而算出输入的量是多少
        //解释：计算池中预期剩余的 token0 数量 _reserve0 - amount0Out，即扣除掉已经发送给 to 的 amount0Out 后的数量。
        //检查当前余额 balance0 是否大于预期余额 _reserve0 - amount0Out，如果大于，说明有新的 token0 进入池中，进入池中的数量为 balance0 - (_reserve0 - amount0Out)；
        // 否则，没有新的 token0 进入池中，amount0In 为 0。
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        //如果 余额1 > 储备1 - amount1Out 则 amount1In = 余额1 - (储备1 - amount1Out) 否则 amount1In = 0
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        //确认`输入数量0||1`大于0
        require(amount0In > 0 || amount1In > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");

        {
            //标记reserve{0,1}的作用域，避免堆栈太深的错误
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors

            //调整后的余额0 = 余额0 * 1000 - (amount0In * 3)
            // 详细解释：1.balance0 是交易后的 token0 余额；2.amount0In 是进入池中的 token0 数量；3.balance0Adjusted 是调整后的 token0 余额
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            //调整后的余额1 = 余额1 * 1000 - (amount1In * 3)
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            //确认 balance0Adjusted * balance1Adjusted >= 储备0 * 储备1 * 1000000
            // ==> 这里 储备0 * 储备1 即为 x*y
            // ==> 核心目的是校验收过税了（0.3%），以防止绕过路由合约直接调当前合约做 swap(这样就收不到税)
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000 ** 2),
                "UniswapV2: K"
            );
        }

        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //触发交换事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
     * @param to to地址
     * @dev 强制平衡以匹配储备：按照储备量去匹配余额
     * 作用：是将多余的 token0 和 token1 从合约中转移到指定的地址 to。这种多余的代币可能由于意外或故意转移而存在。它是一种清理机制，确保合约中只保留必要的储备量。
     * 用于清理意外或多余的代币，确保合约中的代币数量准确无误。它在意外转账、流动性调整以及复杂交易后的清算等场景中非常有用。通过将多余的代币转移到指定地址，skim 函数维护了合约的清晰性和准确性。
     */
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        //将当前合约在`token0,1`的余额-`储备量0,1`安全发送到to地址
        // ==> 当前合约在 2 个 Token 身上的余额如果比记录的储备量多，
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /**
     * @dev 强制准备金与余额匹配：按照余额去匹配储备量
     *  作用是同步储备量，以确保合约的内部状态与实际持有的代币数量一致。这在处理意外转账、状态不一致修复以及复杂操作后的状态恢复等场景中非常有用。
     *  通过调用 sync 函数，可以手动触发储备量更新，确保合约的操作准确无误。
     */
    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
