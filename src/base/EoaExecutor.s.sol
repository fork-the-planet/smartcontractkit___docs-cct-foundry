// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CctActions} from "../actions/CctActions.sol";

/// @title EoaExecutor
/// @notice The EOA execution mode of the action layer: takes the `Call[]` a `CctActions` builder
///         produced, broadcasts each call in order from the script signer, and logs each target and
///         function selector. Scripts inherit this instead of calling contracts inline, so the calldata
///         a user reviews in the logs is exactly the calldata the action layer built.
abstract contract EoaExecutor is Script {
    /// @notice Broadcasts every call in order, reverting on the first failure (atomic batch semantics —
    ///         a dry run surfaces the revert before anything is sent).
    function executeCalls(CctActions.Call[] memory calls) internal {
        vm.startBroadcast();
        for (uint256 i = 0; i < calls.length; i++) {
            console.log(
                string.concat(
                    "  Executing call ",
                    vm.toString(i + 1),
                    "/",
                    vm.toString(calls.length),
                    ": target ",
                    vm.toString(calls[i].target),
                    " selector ",
                    vm.toString(abi.encodePacked(bytes4(calls[i].data)))
                )
            );
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) {
                // Bubble up the underlying contract's revert reason unchanged.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
        vm.stopBroadcast();
    }

    /// @notice Resolves the account the script will broadcast with (keystore --account, --private-key,
    ///         or the default sender), so wrappers can run their preflight checks against it before any
    ///         transaction is sent.
    function broadcaster() internal returns (address account) {
        vm.startBroadcast();
        (, account,) = vm.readCallers();
        vm.stopBroadcast();
    }
}
