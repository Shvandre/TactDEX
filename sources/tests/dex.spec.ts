/* eslint-disable @typescript-eslint/no-unused-vars */
import {Address, beginCell, Cell, toNano} from "@ton/core"
import {Blockchain, SandboxContract, TreasuryContract, BlockchainSnapshot} from "@ton/sandbox"
import {ExtendedJettonMinter as JettonMinter} from "../wrappers/ExtendedJettonMinter"
import {randomAddress} from "@ton/test-utils"
import {ExtendedJettonWallet as JettonWallet} from "../wrappers/ExtendedJettonWallet"
import {JettonVault} from "../output/DEX_JettonVault"
import {AmmPool} from "../output/DEX_AmmPool"
import {LiquidityDepositContract} from "../output/DEX_LiquidityDepositContract"
import {
    // eslint-disable-next-line
    serializeTransactionsList,
    createJettonVaultSwapRequest,
    createJettonVaultLiquidityDepositPayload,
} from "../utils/testUtils"
// eslint-disable-next-line
import fs from "fs"
import {sortAddresses} from "../utils/deployUtils"

type ContractCodeData = {
    code: Cell | undefined
    data: Cell | undefined
}

describe("contract", () => {
    let blockchain: Blockchain
    let deployer: SandboxContract<TreasuryContract>

    let userWalletA: (address: Address) => Promise<SandboxContract<JettonWallet>>
    let userWalletB: (address: Address) => Promise<SandboxContract<JettonWallet>>
    let userLPWallet: (owner: Address, pool: Address) => Promise<SandboxContract<JettonWallet>>
    let jettonVault: (address: Address) => Promise<SandboxContract<JettonVault>>
    let ammPool: (vaultLeft: Address, vaultRight: Address) => Promise<SandboxContract<AmmPool>>
    const depositorIds: Map<string, bigint> = new Map()
    let liquidityDepositContract: (
        depositor: Address,
        vaultLeft: Address,
        vaultRight: Address,
        amountLeft: bigint,
        amountRight: bigint,
    ) => Promise<SandboxContract<LiquidityDepositContract>>

    let tokenA: SandboxContract<JettonMinter>
    let tokenACodeData: ContractCodeData
    let tokenB: SandboxContract<JettonMinter>
    let tokenBCodeData: ContractCodeData
    let vaultForA: SandboxContract<JettonVault>
    let vaultForB: SandboxContract<JettonVault>

    let snapshot: BlockchainSnapshot

    beforeAll(async () => {
        blockchain = await Blockchain.create()
        //blockchain.verbosity.vmLogs = "vm_logs_full";
        //blockchain.verbosity.vmLogs = "vm_logs_verbose";
        deployer = await blockchain.treasury("deployer")

        // Two different jettonMaster addresses, as jettonContent is different
        tokenA = blockchain.openContract(
            await JettonMinter.fromInit(
                0n,
                deployer.address,
                beginCell().storeInt(0x01, 6).endCell(),
            ),
        )
        tokenACodeData = {
            code: tokenA.init?.code,
            data: tokenA.init?.data,
        }
        tokenB = blockchain.openContract(
            await JettonMinter.fromInit(
                0n,
                deployer.address,
                beginCell().storeInt(0x02, 6).endCell(),
            ),
        )
        tokenBCodeData = {
            code: tokenB.init?.code,
            data: tokenB.init?.data,
        }
        userWalletA = async (address: Address) => {
            return blockchain.openContract(
                new JettonWallet(await tokenA.getGetWalletAddress(address)),
            )
        }

        userWalletB = async (address: Address) => {
            return blockchain.openContract(
                new JettonWallet(await tokenB.getGetWalletAddress(address)),
            )
        }

        vaultForA = blockchain.openContract(await JettonVault.fromInit(tokenA.address, false, null))
        vaultForB = blockchain.openContract(await JettonVault.fromInit(tokenB.address, false, null))

        jettonVault = async (address: Address) => {
            return blockchain.openContract(await JettonVault.fromInit(address, false, null))
        }

        ammPool = async (vaultLeft: Address, vaultRight: Address) => {
            let sortedAddresses = sortAddresses(vaultLeft, vaultRight, 0n, 0n)
            return blockchain.openContract(
                await AmmPool.fromInit(sortedAddresses.lower, sortedAddresses.higher, 0n, 0n, 0n),
            )
        }

        userLPWallet = async (owner: Address, pool: Address) => {
            return blockchain.openContract(await JettonWallet.fromInit(0n, owner, pool))
        }

        liquidityDepositContract = async (
            depositor: Address,
            vaultLeft: Address,
            vaultRight: Address,
            amountLeft: bigint,
            amountRight: bigint,
        ): Promise<SandboxContract<LiquidityDepositContract>> => {
            const depositorKey = depositor.toRawString()
            let contractId = depositorIds.get(depositorKey) || 0n
            depositorIds.set(depositorKey, contractId + 1n)

            let sortedAddresses = sortAddresses(vaultLeft, vaultRight, amountLeft, amountRight)
            return blockchain.openContract(
                await LiquidityDepositContract.fromInit(
                    sortedAddresses.lower,
                    sortedAddresses.higher,
                    sortedAddresses.leftAmount,
                    sortedAddresses.rightAmount,
                    depositor,
                    contractId,
                    0n,
                ),
            )
        }

        const mintRes = await tokenA.sendMint(
            deployer.getSender(),
            deployer.address,
            1000000000n,
            0n,
            toNano(1),
        )
        expect(mintRes.transactions).toHaveTransaction({
            deploy: true,
            success: true,
        })

        const mintRes2 = await tokenB.sendMint(
            deployer.getSender(),
            deployer.address,
            1000000000n,
            0n,
            toNano(1),
        )
        expect(mintRes2.transactions).toHaveTransaction({
            deploy: true,
            success: true,
        })

        snapshot = blockchain.snapshot()
    })

    beforeEach(async () => {
        await blockchain.loadFrom(snapshot)
    })

    test("Jetton vault should deploy correctly", async () => {
        const mockDepositLiquidityContract = randomAddress(0)

        const realDeployment = await vaultForA.send(
            deployer.getSender(),
            {value: toNano(0.1), bounce: false},
            null,
        )

        expect(realDeployment.transactions).toHaveTransaction({
            success: true,
            deploy: true,
        })

        const deployerWallet = await userWalletA(deployer.address)
        const transferRes = await deployerWallet.sendTransfer(
            deployer.getSender(),
            toNano(1),
            100n,
            vaultForA.address,
            deployer.address,
            null,
            toNano(0.5),
            createJettonVaultLiquidityDepositPayload(
                mockDepositLiquidityContract,
                tokenACodeData.code!!,
                tokenACodeData.data!!,
            ),
        )

        expect(transferRes.transactions).toHaveTransaction({
            success: true,
        })

        expect(transferRes.transactions).toHaveTransaction({
            to: mockDepositLiquidityContract,
        })

        const inited = await vaultForA.getInited()
        expect(inited).toBe(true)
    })

    // TODO: fix snapshot deps
    test.skip("Swap with slippage should revert correctly", async () => {
        const vaultA = await jettonVault(tokenA.address)
        const vaultB = await jettonVault(tokenB.address)
        const ammPoolForAB = await ammPool(vaultA.address, vaultB.address)

        const amountToSwap = 100n
        const walletA = await userWalletA(deployer.address)
        const tokenABeforeSwap = await walletA.getJettonBalance()
        const walletB = await userWalletB(deployer.address)
        const tokenBBeforeSwap = await walletB.getJettonBalance()
        const expectedOutput = await ammPoolForAB.getExpectedOut(vaultA.address, amountToSwap)
        console.log("Expected output: ", expectedOutput)
        console.log("Pool address: ", ammPoolForAB.address.toString())
        // Expected output field is unsigned

        const swapRequest = await walletA.sendTransfer(
            deployer.getSender(),
            toNano(1),
            amountToSwap,
            vaultForA.address,
            deployer.address,
            null,
            toNano(0.5),
            createJettonVaultSwapRequest(vaultB.address, expectedOutput + 1n),
        )
        expect(swapRequest.transactions).toHaveTransaction({
            from: vaultForA.address,
            to: ammPoolForAB.address,
            success: true,
        })
        expect(swapRequest.transactions).toHaveTransaction({
            from: vaultForA.address,
            to: ammPoolForAB.address, //NOTE: Swap should fail
            exitCode: AmmPool.errors["Amount out is less than minAmountOut"],
            success: true, // That is what happens when throw after commit(), exit code is non-zero, success is true
        })
        const tokenAAfterSwap = await walletA.getJettonBalance()
        const tokenBAfterSwap = await walletB.getJettonBalance()
        expect(tokenAAfterSwap).toEqual(tokenABeforeSwap)
        expect(tokenBAfterSwap).toEqual(tokenBBeforeSwap)
    })

    test.skip("Swap should work correctly", async () => {
        const vaultA = await jettonVault(tokenA.address)
        const vaultB = await jettonVault(tokenB.address)
        const ammPoolForAB = await ammPool(vaultA.address, vaultB.address)

        console.log(
            "Amm rate before swap: ",
            await ammPoolForAB.getGetLeftSide(),
            "/",
            await ammPoolForAB.getGetRightSide(),
        )
        const amountToSwap = 10n

        const walletA = await userWalletA(deployer.address)
        const walletB = await userWalletB(deployer.address)

        const amountOfTokenB = await walletB.getJettonBalance()
        console.log(`Sending ${amountToSwap} of token A for swap`)

        const expectedOutput = await ammPoolForAB.getExpectedOut(vaultA.address, amountToSwap)

        const swapRequest = await walletA.sendTransfer(
            deployer.getSender(),
            toNano(1),
            amountToSwap,
            vaultForA.address,
            deployer.address,
            null,
            toNano(0.5),
            createJettonVaultSwapRequest(vaultB.address, expectedOutput),
        )
        expect(swapRequest.transactions).toHaveTransaction({
            from: vaultForA.address,
            to: ammPoolForAB.address,
            success: true,
        })
        expect(swapRequest.transactions).toHaveTransaction({
            from: ammPoolForAB.address,
            to: vaultB.address,
            success: true,
        })
        console.log("Vault B address: ", vaultB.address.toString())
        const vaultBWallet = await userWalletB(vaultB.address)
        expect(swapRequest.transactions).toHaveTransaction({
            from: vaultB.address,
            to: vaultBWallet.address,
            success: true,
        })
        expect(swapRequest.transactions).toHaveTransaction({
            from: vaultBWallet.address,
            to: walletB.address,
            success: true,
        })
        expect(swapRequest.transactions).toHaveTransaction({
            from: walletB.address,
            to: deployer.address,
        })

        const amountOfTokenBAfterSwap = await walletB.getJettonBalance()
        console.log("Received ", amountOfTokenBAfterSwap - amountOfTokenB, " of token B")
        expect(amountOfTokenBAfterSwap).toBeGreaterThan(amountOfTokenB)

        console.log(
            "Amm rate after swap: ",
            await ammPoolForAB.getGetLeftSide(),
            "/",
            await ammPoolForAB.getGetRightSide(),
        )
    })

    test.skip("Liquidity withdraw should work correctly", async () => {
        const vaultA = await jettonVault(tokenA.address)
        const vaultB = await jettonVault(tokenB.address)
        const ammPoolForAB = await ammPool(vaultA.address, vaultB.address)
        const lpWallet = await userLPWallet(deployer.address, ammPoolForAB.address)
        const balanceOfLP = await lpWallet.getJettonBalance()
        expect(balanceOfLP).toBeGreaterThan(0n)
        console.log("Balance of LP: ", balanceOfLP)

        const balanceOfTokenABefore = await (await userWalletA(deployer.address)).getJettonBalance()
        const balanceOfTokenBBefore = await (await userWalletB(deployer.address)).getJettonBalance()

        const withdrawLiquidity = await lpWallet.sendBurn(
            deployer.getSender(),
            toNano(1),
            balanceOfLP,
            deployer.address,
            null,
        )
        expect(withdrawLiquidity.transactions).toHaveTransaction({
            from: lpWallet.address,
            to: ammPoolForAB.address,
            op: AmmPool.opcodes.LiquidityWithdrawViaBurnNotification,
            success: true,
        })
        expect(withdrawLiquidity.transactions).toHaveTransaction({
            from: ammPoolForAB.address,
            to: vaultA.address,
            op: AmmPool.opcodes.PayoutFromPool,
            success: true,
        })
        expect(withdrawLiquidity.transactions).toHaveTransaction({
            from: ammPoolForAB.address,
            to: vaultB.address,
            op: AmmPool.opcodes.PayoutFromPool,
            success: true,
        })

        const balanceOfTokenAAfter = await (await userWalletA(deployer.address)).getJettonBalance()
        const balanceOfTokenBAfter = await (await userWalletB(deployer.address)).getJettonBalance()

        console.log("Got ", balanceOfTokenAAfter - balanceOfTokenABefore, " of token A")
        console.log("Got ", balanceOfTokenBAfter - balanceOfTokenBBefore, " of token B")
        expect(balanceOfTokenAAfter).toBeGreaterThan(balanceOfTokenABefore)
        expect(balanceOfTokenBAfter).toBeGreaterThan(balanceOfTokenBBefore)
    })

    //TODO: Swap after liquidity withdraw
})
