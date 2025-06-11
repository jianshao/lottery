// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/Lottery.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployLottery is Script {
    function run()
        external
        returns (
            Lottery lotteryProxy,
            address proxyAddress,
            address implementationAddress
        )
    {
        uint256 deployPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        if (deployPrivateKey == 0) {
            // 对于本地测试，Anvil 的第一个账户通常是这个
            deployPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        address deployerAddress = vm.rememberKey(deployPrivateKey);

        vm.startBroadcast(deployPrivateKey);
        // 开始部署合约
        Lottery lotteryImplementation = new Lottery();
        implementationAddress = address(lotteryImplementation);
        console.log(
            "Lottery Implementation deployed to:",
            implementationAddress
        );

        // 对逻辑合约进行初始化
        bytes memory initializeData = abi.encodeWithSelector(
            Lottery.initialize.selector,
            deployerAddress
        );

        ERC1967Proxy proxy = new ERC1967Proxy(
            implementationAddress,
            initializeData
        );
        proxyAddress = address(proxy);
        console.log("Lottery Proxy deployed to:", proxyAddress);

        lotteryProxy = Lottery(payable(proxyAddress));

        vm.stopBroadcast();

        return (lotteryProxy, proxyAddress, implementationAddress);
    }
}
