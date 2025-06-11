// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

struct RewardInfo {
    address payable winner;
    uint256 amount;
}

enum LotteryStatus {
    Initialed, // 初始状态
    Registering, // 开奖之前等待其他用户报名
    Drawing, // 开奖中
    Drawn,
    Rewarding, // 奖励发放中
    Rewarded // 奖励发放结束，有可能有人没有领取奖励。最终状态
}

// 只存储状态数据，减少存储空间，节省gas
struct LotteryInfo {
    // uint256 lotteryId;
    // address creator;
    // string name;
    // string desc;
    // uint8 rewardType;
    // uint256[] rewards;
    // uint256 drawingTime;
    // uint8 deletedFlag;
    // LotteryTicket[] tickets;
    mapping(address => uint32) registerScores; // mapping固定占用一个存储槽, 映射的value是score，初始值是1。
    address[] registers; // 遍历报名用户使用。
    RewardInfo[] rewards; // 获奖用户
    LotteryStatus status; // 枚举变量占用空间跟枚举数量有关，此处只需要8bit
    uint32 lotteryId; // 与status可以打包在一个存储槽中，单个存储槽空间是256bit
}

struct User {
    address creator; // 用户地址
    mapping(uint32 => LotteryInfo) lotteries; // 用户创建的彩票活动
}

contract Lottery is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // 合约部署人，使用UUPS的实现
    // address public owner;

    // 需要存储创建者列表，避免任何人随意创建抽奖活动
    mapping(address => User) private authorizedCreators;

    // 合约部署时设置owner，必须这样做
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // UUPS 要求构造函数调用 _disableInitializers
        // 以防止实现合约在没有代理的情况下被意外初始化。
        _disableInitializers();
    }

    function initialize(address owner) public virtual initializer {
        // 初始化 UUPS 功能
        __UUPSUpgradeable_init();
        // 初始化所有权，将 initialOwner 设为 owner
        __Ownable_init(owner);

        // 初始化业务数据
    }

    function _authorizeUpgrade(address dev) internal override onlyOwner {}

    // 合约部署后是公开的，不像传统网络服务有网络隔离，必须要有严格的权限控制
    // modifier onlyOwner() {
    //     require(msg.sender == owner, "Only owner.");
    //     _;
    // }

    // public代表外部可以读写，全局变量默认是storage（存储于链上），还是memory（可读写的临时变量）、calldata（只读临时变量）
    // 使用额外映射保存用户是否存在，映射是稀疏数据，能节省gas
    modifier onlyAuthorizedCreator() {
        require(
            authorizedCreators[msg.sender].creator != address(0),
            "Creators not exists."
        );
        _;
    }

    // 增加活动呢创建者，外部接口
    function AddCreator(address creator) external onlyOwner {
        require(creator != address(0), "Invalid creator address.");
        // 已存在时不能被覆盖
        require(
            authorizedCreators[creator].creator == address(0),
            "Creator already exist."
        );

        // mapping是特殊的，不允许直接赋值，子结构中包含mapping的也不行
        User storage creatorUser = authorizedCreators[creator];
        creatorUser.creator = creator;
    }

    // 某些操作触发事件通知，常用于日志记录等链下信息记录
    event LotteryCreated(address indexed creator, uint32 indexed lotteryId);

    // calldata指明变量只读，external修饰函数（外部可访问），还有internal（只有内部访问）
    // pure（修饰函数对数据不可读写，常用于对输入参数进行加工的工具函数）、view（可读不可写）
    function CreateLottery(uint32 lotteryId) external onlyAuthorizedCreator {
        require(lotteryId != 0, "Invalid lottery Id.");
        User storage creator = authorizedCreators[msg.sender];
        // lottery 已存在时避免被覆盖
        require(
            creator.lotteries[lotteryId].lotteryId == 0,
            "Lottery already exists."
        );

        LotteryInfo storage lottery = creator.lotteries[lotteryId];
        lottery.status = LotteryStatus.Initialed;
        lottery.lotteryId = lotteryId;

        // 通知lottery已创建
        emit LotteryCreated(msg.sender, lotteryId);
    }

    event StartRegisterEvent(address indexed creator, uint32 indexed lotteryId);

    function StartRegister(uint32 lotteryId) external onlyAuthorizedCreator {
        require(lotteryId != 0, "Invalid lottery Id.");
        LotteryInfo storage lottery = authorizedCreators[msg.sender].lotteries[
            lotteryId
        ];
        require(lottery.lotteryId != 0, "Lottery not exists.");
        require(
            lottery.status == LotteryStatus.Initialed,
            "Invalid lottery status, must be {LotteryStatus.Initialed}."
        );

        lottery.status = LotteryStatus.Registering;

        emit StartRegisterEvent(msg.sender, lotteryId);
    }

    struct RegisterUser {
        address register;
        uint32 score;
    }

    event LotteryDrawn(
        address indexed creator,
        uint32 indexed lotteryId,
        RewardInfo[] winners
    );
    // 将报名用户数据作为参数传入，简化合约上执行的操作内容。
    // 入参会消耗gas，需要控制入参大小

    function DrawingLottery(
        uint32 lotteryId,
        uint32[] calldata rewardAmounts
    ) external onlyAuthorizedCreator {
        require(lotteryId != 0, "Invalid lottery Id.");
        LotteryInfo storage lottery = authorizedCreators[msg.sender].lotteries[
            lotteryId
        ];
        require(lottery.lotteryId != 0, "Lottery not exist");
        require(
            lottery.status == LotteryStatus.Registering,
            "Lottery: invalid status, expect Registering."
        );

        lottery.status = LotteryStatus.Drawing;
        // 这么做是考虑合约透明度问题，避免怀疑。
        // 先计算所有报名用户的得分总和，作为随机数的上限
        uint256 total = 0;
        // 对应映射，无法直接从storage复制出来，因为映射无法复制。此时仍然是引用，这么写仅仅是提高代码可读性。
        mapping(address => uint32) storage scores = lottery.registerScores;
        // 对于数组，可以用memory减少gas消耗。
        address[] memory registers = lottery.registers;
        // ++i略优于i++，因为少了一次赋值操作
        unchecked {
            for (uint32 i = 0; i < registers.length; ++i) {
                total += scores[registers[i]];
            }
        }

        RewardInfo[] memory rewards = new RewardInfo[](rewardAmounts.length);
        // 根据[1, total]之间生成n个随机数。检查是否有一次生成多个随机数的方式！！！
        for (uint32 i = 0; i < rewardAmounts.length; ++i) {
            // 生成随机数
            uint256 pseudoRandomSeed = uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        block.prevrandao,
                        msg.sender,
                        i,
                        lotteryId
                    )
                )
            );
            uint256 numToSelect = (pseudoRandomSeed % total) + 1; // 生成一个 [1, total] 之间的伪随机数

            // numToSelect在逻辑中做了检查，使用unchecked节省gas。
            unchecked {
                // 根据得分的分布确定获奖用户，有可能会出现同一用户获奖多次的情况（要排除）。
                for (uint32 j = 0; j < registers.length; ++j) {
                    if (numToSelect <= scores[registers[j]]) {
                        rewards[i] = RewardInfo({
                            winner: payable(registers[j]),
                            amount: rewardAmounts[i]
                        });
                        break;
                    }
                    numToSelect -= scores[registers[j]];
                }
            }
        }
        // 对storage的数据尽量只做一次赋值，减少SSTORE次数（gas消耗大）。
        for (uint256 i = 0; i < rewards.length; ++i) {
            lottery.rewards.push(rewards[i]);
        }
        // lottery.rewards = rewards;
        emit LotteryDrawn(msg.sender, lotteryId, lottery.rewards);
        lottery.status = LotteryStatus.Drawn;
    }

    event LotteryRewarded(address indexed creator, uint32 indexed lotteryId);
    // 只有活动发布方才能触发发放奖励

    function Reward(uint32 lotteryId) external onlyAuthorizedCreator {
        require(lotteryId != 0, "Invalid lottery Id.");
        // onlyCreator保证了authorizedCreators[msg.sender]一定存在。
        LotteryInfo storage lottery = authorizedCreators[msg.sender].lotteries[
            lotteryId
        ];
        require(lottery.lotteryId != 0, "Lottery not exist");
        require(
            lottery.status == LotteryStatus.Drawn,
            "Lottery: invalid lottery status, expect Drawn."
        );

        lottery.status = LotteryStatus.Rewarding;
        RewardInfo memory reward;
        // 执行发奖，发奖的资金来源先不考虑，以熟悉功能实现为主
        for (uint32 i = 0; i < lottery.rewards.length; ++i) {
            reward = lottery.rewards[i];
            // 通常情况下获奖者需要是用户地址，而非合约地址。增加返回值的判断。
            reward.winner.call{value: reward.amount}("");
        }
        lottery.status = LotteryStatus.Rewarded;

        emit LotteryRewarded(msg.sender, lotteryId);
    }

    event Registered(address indexed register, uint32 indexed lotteryId);

    // 普通用户报名活动
    function Register(address creator, uint32 lotteryId) external {
        require(creator != address(0), "Invalid creator address.");
        require(lotteryId != 0, "Invalid lottery Id.");
        User storage lotteryCreator = authorizedCreators[creator];
        // 提供的创建者必须正确
        require(lotteryCreator.creator != address(0), "Creator not exists.");
        LotteryInfo storage lottery = lotteryCreator.lotteries[lotteryId];
        // lottery必须存在
        require(lottery.lotteryId != 0, "Lottery not exists.");
        // lottery 状态判断
        require(
            lottery.status == LotteryStatus.Registering,
            "Lottery is not Registering."
        );

        // 报名人不可重复报名
        require(
            lottery.registerScores[msg.sender] == 0,
            "Register already exists."
        );

        // 执行报名操作，报名用户的初始得分为1。
        lottery.registerScores[msg.sender] = 1;
        lottery.registers.push(msg.sender);

        // 链上任务执行完成
        emit Registered(msg.sender, lotteryId);
    }
}
