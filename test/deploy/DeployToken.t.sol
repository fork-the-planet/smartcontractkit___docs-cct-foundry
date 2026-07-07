// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork tests for script/deploy/DeployToken.s.sol: the deployed token must match
/// script/input/token.json and mint/burn roles must be granted to the deployer.
contract DeployTokenForkTest is BaseForkTest {
    CrossChainToken internal token;

    function setUp() public override {
        super.setUp();
        token = CrossChainToken(deployTokenFixture());
    }

    function test_DeployToken_MatchesTokenJsonConfig() public view {
        string memory json = vm.readFile(TOKEN_JSON_PATH);

        assertEq(token.name(), vm.parseJsonString(json, ".name"), "name mismatch vs token.json");
        assertEq(token.symbol(), vm.parseJsonString(json, ".symbol"), "symbol mismatch vs token.json");
        assertEq(token.decimals(), uint8(vm.parseJsonUint(json, ".decimals")), "decimals mismatch vs token.json");
        assertEq(token.maxSupply(), vm.parseJsonUint(json, ".maxSupply"), "maxSupply mismatch vs token.json");
        assertEq(token.totalSupply(), vm.parseJsonUint(json, ".preMint"), "totalSupply mismatch vs preMint");
    }

    function test_DeployToken_GrantsRolesToDeployer() public view {
        // In tests the script's vm.startBroadcast() broadcaster is forge's default sender.
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), DEFAULT_SENDER), "deployer missing DEFAULT_ADMIN_ROLE");
        assertTrue(token.hasRole(token.BURN_MINT_ADMIN_ROLE(), DEFAULT_SENDER), "deployer missing BURN_MINT_ADMIN_ROLE");
        assertTrue(token.hasRole(token.MINTER_ROLE(), DEFAULT_SENDER), "deployer missing MINTER_ROLE");
        assertTrue(token.hasRole(token.BURNER_ROLE(), DEFAULT_SENDER), "deployer missing BURNER_ROLE");
    }
}
