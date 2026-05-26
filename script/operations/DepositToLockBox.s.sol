// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperConfig} from "../HelperConfig.s.sol";
import {ERC20LockBox} from "@chainlink/contracts-ccip/contracts/pools/ERC20LockBox.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";

/**
 * @title DepositToLockBox
 * @notice Script to deposit tokens into an ERC20LockBox
 * @dev Useful for token issuers to manually manage liquidity in the lockbox.
 *      Requires the caller to be an authorized caller on the lockbox.
 *
 * Usage:
 *   LOCK_BOX=0x... forge script script/operations/DepositToLockBox.s.sol --rpc-url $ETHEREUM_SEPOLIA_RPC_URL --account $KEYSTORE_NAME --broadcast
 *
 * Environment variables:
 *   LOCK_BOX   — (required) address of the ERC20LockBox contract
 *   AMOUNT     — (optional) amount to deposit (defaults to tokenAmountToTransfer from script/input/token.json)
 */
contract DepositToLockBox is Script {
    HelperConfig public helperConfig;

    function run() external {
        helperConfig = new HelperConfig();
        uint256 chainId = block.chainid;
        string memory chainName = helperConfig.getChainName(chainId);

        address lockBoxAddress = vm.envAddress("LOCK_BOX");
        require(lockBoxAddress != address(0), "LOCK_BOX environment variable not set");

        console.log("");
        console.log("========================================");
        console.log(unicode"📥 Deposit to LockBox");
        console.log("========================================");
        console.log(string.concat("Chain:        ", chainName));
        console.log(string.concat("LockBox:      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("Action:       ", "Deposit to lockbox"));
        console.log("========================================");
        console.log("");

        ERC20LockBox lockBox = ERC20LockBox(lockBoxAddress);

        // Get token address from HelperConfig
        address tokenAddress = helperConfig.getDeployedToken(chainId);
        require(
            tokenAddress != address(0),
            string.concat(
                "Token not deployed. Set the ",
                helperConfig.getNetworkConfig(chainId).chainNameIdentifier,
                "_TOKEN environment variable. Alternatively, use the inline alias TOKEN=0x..."
            )
        );

        // Verify lockbox supports this token
        require(lockBox.isTokenSupported(tokenAddress), "Token not supported by this lockbox");

        // Get amount to deposit — falls back to tokenAmountToTransfer in script/input/token.json if not set
        string memory tokenJson = vm.readFile("script/input/token.json");
        uint256 defaultAmount = vm.parseJsonUint(tokenJson, ".tokenAmountToTransfer");
        uint256 amount = vm.envOr("AMOUNT", defaultAmount);
        require(
            amount > 0,
            "Invalid amount to deposit. Set AMOUNT env var or tokenAmountToTransfer in script/input/token.json"
        );

        IERC20 token = IERC20(tokenAddress);

        vm.startBroadcast();

        (, address broadcaster,) = vm.readCallers();

        console.log("Deposit Parameters:");
        console.log(string.concat("  LockBox:                      ", vm.toString(lockBoxAddress)));
        console.log(string.concat("  Token:                        ", vm.toString(tokenAddress)));
        console.log(string.concat("  Depositor:                    ", vm.toString(broadcaster)));
        console.log(string.concat("  Amount:                       ", vm.toString(amount)));
        console.log("");

        uint256 balanceBefore = token.balanceOf(broadcaster);
        require(balanceBefore >= amount, "Insufficient token balance");

        console.log(string.concat("[Step 1] Approving ", vm.toString(amount), " tokens to LockBox"));
        token.approve(lockBoxAddress, amount);
        console.log(unicode"✅ Approval successful!");

        console.log(string.concat("\n[Step 2] Depositing ", vm.toString(amount), " tokens into LockBox"));
        lockBox.deposit(tokenAddress, 0, amount); // remoteChainSelector is unused, pass 0
        console.log(unicode"✅ Deposit successful!");

        vm.stopBroadcast();

        uint256 balanceAfter = token.balanceOf(broadcaster);
        uint256 lockBoxBalance = token.balanceOf(lockBoxAddress);

        console.log("");
        console.log("========================================");
        console.log(string.concat(unicode"✅ Deposit Complete on ", chainName, "!"));
        console.log("========================================");
        console.log(string.concat("Depositor Balance Before: ", vm.toString(balanceBefore)));
        console.log(string.concat("Depositor Balance After: ", vm.toString(balanceAfter)));
        console.log(string.concat("LockBox Balance: ", vm.toString(lockBoxBalance)));
        console.log("========================================");
        console.log("");
    }
}
