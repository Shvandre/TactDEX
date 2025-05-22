import {Blockchain} from "@ton/sandbox"
import {createJetton, createTonVault} from "../utils/environment"
import {beginCell} from "@ton/core"
import {findTransactionRequired, flattenTransaction} from "@ton/test-utils"
import {randomInt} from "node:crypto"
import {TonVault} from "../output/DEX_TonVault"

describe("TON Vault", () => {
    test("Jettons are returned if sent to TON Vault", async () => {
        const blockchain = await Blockchain.create()
        const vaultSetup = await createTonVault(blockchain)

        const _ = await vaultSetup.deploy()
        const mockActionPayload = beginCell().storeStringTail("Random payload").endCell()

        const jetton = await createJetton(blockchain)
        const initialBalance = await jetton.wallet.getJettonBalance()
        const numberOfJettons = BigInt(randomInt(0, 100000000000))
        const sendResult = await jetton.transfer(
            vaultSetup.vault.address,
            numberOfJettons,
            mockActionPayload,
        )

        const toVaultTx = flattenTransaction(
            findTransactionRequired(sendResult.transactions, {
                to: vaultSetup.vault.address,
                op: TonVault.opcodes.UnexpectedJettonNotification,
                success: true, // Because commit was called
                exitCode:
                    TonVault.errors[
                        "TonVault: Jetton transfer must be performed to correct Jetton Vault"
                    ],
            }),
        )

        expect(sendResult.transactions).toHaveTransaction({
            from: vaultSetup.vault.address,
            to: toVaultTx.from,
            op: TonVault.opcodes.ReturnJettonsViaJettonTransfer,
            success: true,
        })
        const finalJettonBalance = await jetton.wallet.getJettonBalance()
        expect(finalJettonBalance).toEqual(initialBalance)
    })
})
