import "./tep-89-proofer.tact";
import "./tep-89-proofer";
import "./calculate-jetton-wallet";
import "../../utils/utils";

struct JettonMasterState {
    jettonMasterCode: Cell?;
    jettonMasterData: Cell?;
}

const PROOF_NO_PROOF_ATTACHED: Int = 0;
const PROOF_TEP89: Int = 1;
const PROOF_STATE_INIT: Int = 2;
const PROOF_STATE_TO_THE_BLOCK: Int = 3;
const PROOF_JETTON_BURN: Int = 4;

inline fun checkProof(jettonMaster: Address, proofType: Int, proof: Slice, msgCell: Cell): Bool {
    if (proofType == PROOF_TEP89) {
        let prooferStateInit = initOf TEP89Proofer(
            jettonMaster,
            myAddress(),
            sender(),
            msgCell,
        );

        deploy(DeployParameters {
            mode: SendRemainingValue,
            value: 0,
            // Doesn't really matter, so just for consistency - all internal protocol messages are not bounceable
            bounce: false,
            init: prooferStateInit,
            body: TEP89ProofRequest {
                jettonMaster,
                possibleJettonWallet: sender(),
                action: msgCell,
            }.toCell(),
        });
        // We don't need to save state init, so we just need to exit() quickly
        exit();
    } else if (proofType == PROOF_STATE_INIT) {
        let init = JettonMasterState.fromSlice(proof);
        let myJettonWallet = calculateJettonWallet(myAddress(), init.jettonMasterData, init.jettonMasterCode, jettonMaster);
        require(
            myJettonWallet == sender() &&
            contractAddress(StateInit {
                code: init.jettonMasterCode!!,
                data: init.jettonMasterData!!,
            }) == jettonMaster,
            "JettonVault: StateInit proof is invalid",
        );
        return true;
    } else if (proofType == PROOF_STATE_TO_THE_BLOCK) {
        require(false, "JettonVault: State proof is not supported");
        return true;
    } else if (proofType == PROOF_JETTON_BURN) {
        require(false, "JettonVault: Burn proof is not supported");
        return true;
    }
    return false;
}
