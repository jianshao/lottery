// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

struct LotteryTicket {
    // address participant;
    // uint256 lotterId;
    uint224 reward; // 获得的奖励, 共用同一个存储槽
    uint16 score; // 开奖前增加的中奖权重
    bool exists; // 是否已存在
    // uint256 registerTime;
}

enum LotteryStatus {
    Initialed, // 初始状态
    Registering, // 开奖之前等待其他用户报名
    Drawing, // 开奖中
    Drawn,
    Rewarding, // 奖励发放中
    Rewarded // 奖励发放结束，有可能有人没有领取奖励。最终状态
}
// enum LotteryDeletedFlag {
//     Initted, // 初始状态，未删除
//     Deleted // 已被删除
// }
// enum LotteryRewardType {
//     Amount, // 按照具体数额进行发放奖励
//     Percent, // 按照总收入的比例进行发放奖励
// }
// 只存储状态数据，减少存储空间，节省gas
struct LotteryInfo {
    // uint256 lotteryId;
    // address creator;
    // string name;
    // string desc;
    LotteryStatus status; // 枚举变量占用空间跟枚举数量有关，此处只需要8bit
    uint32 lotteryId; // 与status可以打包在一个存储槽中，单个存储槽空间是256bit
    // uint8 rewardType;
    // uint256[] rewards;
    // uint256 drawingTime;
    // uint8 deletedFlag;
    // LotteryTicket[] tickets;
    mapping(address => LotteryTicket) tickets; // mapping固定占用一个存储槽
}

struct User {
    address creator; // 用户地址
    mapping(uint32 => LotteryInfo) lotteries; // 用户创建的彩票活动
}

contract Lottery is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // 合约部署人
    address public owner;
    // 合约部署时设置owner，必须这样做
    constructor() {
        owner = msg.sender;
    }

    // 合约部署后是公开的，不像传统网络服务有网络隔离，必须要有严格的权限控制
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner.");
        _;
    }

    // 需要存储创建者列表，避免任何人随意创建抽奖活动
    mapping(address => User) private authorizedCreators;

    // public代表外部可以读写，全局变量默认是storage（存储于链上），还是memory（可读写的临时变量）、calldata（只读临时变量）
    // 使用额外映射保存用户是否存在，映射是稀疏数据，能节省gas
    modifier onlyCreator() {
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
    event LotteryCreated(address creator, uint32 lotteryId);

    // calldata指明变量只读，external修饰函数（外部可访问），还有internal（只有内部访问）
    // pure（修饰函数对数据不可读写，常用于对输入参数进行加工的工具函数）、view（可读不可写）
    function CreateLottery(uint32 lotteryId) external onlyCreator {
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

    event StartRegisterEvent(address creator, uint32 lotteryId);
    function StartRegister(uint32 lotteryId) external onlyCreator {
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
    event LotteryDrawn(address creator, uint32 lotteryId, address[] winners);
    // 将报名用户数据作为参数传入，简化合约上执行的操作内容。
    function DrawingLottery(
        uint32 lotteryId,
        RegisterUser[] calldata registers,
        uint32 limit,
        uint32 rewardCount
    ) external onlyCreator returns (address[] memory winners) {
        require(lotteryId != 0, "Invalid lottery Id.");
        LotteryInfo storage lottery = authorizedCreators[msg.sender].lotteries[
            lotteryId
        ];
        require(lottery.lotteryId != 0, "Lottery not exist");
        require(
            lottery.status == LotteryStatus.Registering,
            "Invalid lottery status."
        );

        lottery.status = LotteryStatus.Drawing;
        // 根据[1, limit]之间生成n个随机数。检查是否有一次生成多个随机数的方式！！！
        // address[] memory winners;
        for (uint32 i = 0; i < rewardCount; i++) {
            // 生成随机数
            uint32 num = limit - 1;
            for (uint32 j = 0; j < registers.length; j++) {
                num -= registers[j].score;
                if (num <= 0) {
                    winners[i] = registers[j].register;
                    break;
                }
            }
        }
        emit LotteryDrawn(msg.sender, lotteryId, winners);
        lottery.status = LotteryStatus.Drawn;
        return winners;
    }

    struct RewardInfo {
        address payable winner;
        uint256 reward;
    }
    event LotteryRewarded(
        address creator,
        uint32 lotteryId,
        RewardInfo[] winners
    );
    // 只有活动发布方才能触发发放奖励
    function Reward(
        uint32 lotteryId,
        RewardInfo[] calldata winners
    ) external onlyCreator {
        require(lotteryId != 0, "Invalid lottery Id.");
        // onlyCreator保证了authorizedCreators[msg.sender]一定存在。
        LotteryInfo storage lottery = authorizedCreators[msg.sender].lotteries[
            lotteryId
        ];
        require(lottery.lotteryId != 0, "Lottery not exist");
        require(
            lottery.status == LotteryStatus.Rewarded,
            "Lottery {lotteryId} did not Drawn."
        );

        lottery.status = LotteryStatus.Rewarding;
        // 执行发奖
        RewardInfo calldata winner;
        for (uint8 i = 0; i < winners.length; i++) {
            winner = winners[i];
            winner.winner.transfer(winner.reward);
        }
        lottery.status = LotteryStatus.Rewarded;

        emit LotteryRewarded(msg.sender, lotteryId, winners);
    }

    event Registered(address register, uint32 lotteryId);

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
            !lottery.tickets[msg.sender].exists,
            "Register already exists."
        );

        // 执行报名操作
        lottery.tickets[msg.sender] = LotteryTicket({
            exists: true,
            score: 0,
            reward: 0
        });

        // 链上任务执行完成
        emit Registered(msg.sender, lotteryId);
    }
}
