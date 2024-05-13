pragma solidity =0.5.16;

import "./interfaces/IUniswapV2Factory.sol";
import "./UniswapV2Pair.sol";

// Uniswap 工厂合约
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // 收税员的地址
    address public feeToSetter; //收税员的设置者

    mapping(address => mapping(address => address)) public getPair; // 配对的映射地址 address => address => address
    address[] public allPairs; // 所有的配对地址

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256); // 创建配对的事件

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    /**
     * @notice 获取所有配对地址的数量
     * @return 所有配对地址的数量
     */
    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /**
     * @notice 创建配对
     * @param tokenA tokenA地址
     * @param tokenB tokenB地址
     * @return pair 配对地址
     */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // 确保 tokenA 和 tokenB 地址不相同
        require(tokenA != tokenB, "UniswapV2: IDENTICAL_ADDRESSES");
        // 对 tokenA 和 tokenB 地址进行排序：小的在前，大的在后
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // 检查 token0 和 token1 是否为 0 地址
        require(token0 != address(0), "UniswapV2: ZERO_ADDRESS");
        // 检查待创建的配对不存在
        require(getPair[token0][token1] == address(0), "UniswapV2: PAIR_EXISTS"); // single check is sufficient
        // 获取 UniswapV2Pair 合约的创建代码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 计算配对地址的 salt 值：结合 create2 函数，确保创建的配对地址可以预先计算
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            // 使用 create2 函数创建配对合约，获取配对地址赋值给 pair
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 初始化配对合约
        IUniswapV2Pair(pair).initialize(token0, token1);
        // 配对映射中设置 token0=>token1 = pair
        getPair[token0][token1] = pair;
        // 配对映射中设置 token1=>token0 = pair
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // 将 pair 添加到 allPairs 数组中
        allPairs.push(pair);

        // 触发创建配对事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
     * @notice 设置收税员地址
     * @param _feeTo 收税员地址
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN");
        feeTo = _feeTo;
    }

    /**
     * @notice 设置收税员设置者地址
     * @param _feeToSetter 收税员设置者地址
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, "UniswapV2: FORBIDDEN");
        feeToSetter = _feeToSetter;
    }
}
