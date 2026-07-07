// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BurnMintTokenPool} from "@chainlink/contracts-ccip/contracts/pools/BurnMintTokenPool.sol";
import {CrossChainToken} from "@chainlink/contracts-ccip/contracts/tokens/CrossChainToken.sol";
import {BaseForkTest} from "../BaseForkTest.t.sol";

/// @notice Fork tests for script/deploy/DeployBurnMintTokenPool.s.sol: the pool must be wired
/// to the fixture token, report the expected type and version, and hold mint/burn roles.
contract DeployBurnMintTokenPoolForkTest is BaseForkTest {
    CrossChainToken internal token;
    BurnMintTokenPool internal pool;

    function setUp() public override {
        super.setUp();
        (address tokenAddress, address poolAddress) = deployTokenAndPoolFixture();
        token = CrossChainToken(tokenAddress);
        pool = BurnMintTokenPool(poolAddress);
    }

    function test_DeployBurnMintTokenPool_TypeAndVersion() public view {
        assertEq(pool.typeAndVersion(), "BurnMintTokenPool 2.0.0", "unexpected typeAndVersion");
    }

    function test_DeployBurnMintTokenPool_WiredToFixture() public view {
        assertEq(address(pool.getToken()), address(token), "pool not wired to fixture token");
        assertEq(pool.getTokenDecimals(), token.decimals(), "pool decimals mismatch");
        (address router,,) = pool.getDynamicConfig();
        assertEq(router, networkConfig.router, "pool router mismatch");
        assertEq(pool.getRmnProxy(), networkConfig.rmnProxy, "pool RMN proxy mismatch");
        assertEq(pool.owner(), DEFAULT_SENDER, "pool owner is not the deployer");
    }

    function test_DeployBurnMintTokenPool_HasMintAndBurnRoles() public view {
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(pool)), "pool missing MINTER_ROLE");
        assertTrue(token.hasRole(token.BURNER_ROLE(), address(pool)), "pool missing BURNER_ROLE");
    }
}
