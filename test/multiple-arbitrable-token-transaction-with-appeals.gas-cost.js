const { ethers } = require('@nomiclabs/buidler')
const { readArtifact } = require('@nomiclabs/buidler/plugins')
const { solidity } = require('ethereum-waffle')
const { use, expect } = require('chai')
const {
  randomInt,
  getEmittedEvent,
  latestTime,
  increaseTime
} = require('../src/test-helpers')
const TransactionStatus = require('../src/entities/TransactionStatus')
const TransactionParty = require('../src/entities/TransactionParty')
const DisputeRuling = require('../src/entities/DisputeRuling')

use(solidity)

const { BigNumber } = ethers

describe('MultipleArbitrableTokenTransactionWithAppeals contract', async () => {
  const arbitrationFee = 20
  const arbitratorExtraData = '0x85'
  const appealTimeout = 100
  const feeTimeout = 100
  const timeoutPayment = 100
  const amount = 1000
  const sharedMultiplier = 5000
  const winnerMultiplier = 2000
  const loserMultiplier = 8000
  const NON_PAYABLE_VALUE = BigNumber.from((2n ** 256n - 2n) / 2n)
  const metaEvidenceUri = 'https://kleros.io'

  let arbitrator
  let governor
  let sender
  let receiver
  let other
  let crowdfunder1
  let crowdfunder2

  let senderAddress
  let receiverAddress

  let contract
  let MULTIPLIER_DIVISOR
  let currentTime
  let token

  beforeEach('Setup contracts', async () => {
    ;[
      governor,
      sender,
      receiver,
      other,
      crowdfunder1,
      crowdfunder2
    ] = await ethers.getSigners()
    senderAddress = await sender.getAddress()
    receiverAddress = await receiver.getAddress()

    const arbitratorArtifact = await readArtifact(
      './artifacts/0.4.x',
      'EnhancedAppealableArbitrator'
    )
    const Arbitrator = await ethers.getContractFactory(
      arbitratorArtifact.abi,
      arbitratorArtifact.bytecode
    )
    arbitrator = await Arbitrator.deploy(
      String(arbitrationFee),
      ethers.constants.AddressZero,
      arbitratorExtraData,
      appealTimeout
    )
    await arbitrator.deployed()
    // Make appeals go to the same arbitrator
    await arbitrator.changeArbitrator(arbitrator.address)

    const tokenArtifact = await readArtifact('./artifacts/0.4.x', 'ERC20Mock')
    const ERC20Token = await ethers.getContractFactory(
      tokenArtifact.abi,
      tokenArtifact.bytecode
    )
    token = await ERC20Token.deploy(senderAddress, amount * 10) // (initial account, initial balance)
    await token.deployed()

    const contractArtifact = await readArtifact(
      './artifacts/0.7.x',
      'MultipleArbitrableTokenTransactionWithAppeals'
    )
    const MultipleArbitrableTransaction = await ethers.getContractFactory(
      contractArtifact.abi,
      contractArtifact.bytecode
    )
    contract = await MultipleArbitrableTransaction.deploy(
      arbitrator.address,
      arbitratorExtraData,
      feeTimeout,
      sharedMultiplier,
      winnerMultiplier,
      loserMultiplier
    )
    await contract.deployed()

    // Gas estimations vary if address doesn't have any amount of tokens, so let's initialize it.
    const mintTx = await token.mint(receiverAddress, amount * 10)
    await mintTx.wait()

    const approveTx = await token
      .connect(sender)
      .approve(contract.address, amount * 2)
    await approveTx.wait()
    // The first transaction is more expensive, because the hashes array is empty. Skip it to estimate gas costs on normal conditions.
    await createTransactionHelper(amount)

    MULTIPLIER_DIVISOR = await contract.MULTIPLIER_DIVISOR()
    currentTime = await latestTime()
  })

  describe('Gas costs estimations for single calls', () => {
    it('Estimate gas cost when creating transaction.', async () => {
      const metaEvidence = metaEvidenceUri

      const tx = await contract
        .connect(sender)
        .createTransaction(
          amount,
          token.address,
          timeoutPayment,
          receiverAddress,
          metaEvidence
        )
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by createTransaction():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when reimbursing the sender.', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const reimburseTx = await contract
        .connect(receiver)
        .reimburse(transactionId, transaction, amount)
      const reimburseReceipt = await reimburseTx.wait()

      console.log('')
      console.log(
        '\tGas used by reimburse():  ' + parseInt(reimburseReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying the receiver.', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const payTx = await contract
        .connect(sender)
        .pay(transactionId, transaction, amount)
      const payReceipt = await payTx.wait()

      console.log('')
      console.log('\tGas used by pay():  ' + parseInt(payReceipt.gasUsed))
    })

    it('Estimate gas cost when executing the a transaction.', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      await increaseTime(timeoutPayment)

      // Anyone should be allowed to execute the transaction.
      const executeTx = await contract
        .connect(other)
        .executeTransaction(transactionId, transaction)
      const executeReceipt = await executeTx.wait()

      console.log('')
      console.log(
        '\tGas used by executeTransaction():  ' +
          parseInt(executeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying fee (first party calling).', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()

      console.log('')
      console.log(
        '\tGas used by payArbitrationFeeBySender():  ' +
          parseInt(senderFeeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when paying fee (second party calling) and creating dispute.', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const receiverTxPromise = contract
        .connect(receiver)
        .payArbitrationFeeByReceiver(transactionId, transaction, {
          value: arbitrationFee
        })
      const receiverFeeTx = await receiverTxPromise
      const receiverFeeReceipt = await receiverFeeTx.wait()
      const [
        receiverFeeTransactionId,
        receiverFeeTransaction
      ] = getEmittedEvent('TransactionStateUpdated', receiverFeeReceipt).args

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, receiverFeeTransaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()

      console.log('')
      console.log(
        '\tGas used by payArbitrationFeeBySender():  ' +
          parseInt(senderFeeReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when timing out.', async () => {
      const [
        receipt,
        transactionId,
        transaction
      ] = await createTransactionHelper(amount)

      const senderFeePromise = contract
        .connect(sender)
        .payArbitrationFeeBySender(transactionId, transaction, {
          value: arbitrationFee
        })
      const senderFeeTx = await senderFeePromise
      const senderFeeReceipt = await senderFeeTx.wait()

      const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
        'TransactionStateUpdated',
        senderFeeReceipt
      ).args

      // feeTimeout for receiver passes and sender gets to claim amount and his fee.
      await increaseTime(feeTimeout + 1)
      // Anyone can execute the timeout
      const timeoutTx = await contract
        .connect(other)
        .timeOutBySender(senderFeeTransactionId, senderFeeTransaction)
      const timeoutReceipt = await timeoutTx.wait()

      console.log('')
      console.log(
        '\tGas used by timeOutBySender():  ' + parseInt(timeoutReceipt.gasUsed)
      )
    })

    it('Estimate gas cost when executing a ruled dispute.', async () => {
      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveFinalRulingHelper(disputeID, DisputeRuling.Sender)

      const txPromise = contract
        .connect(other)
        .executeRuling(transactionId, disputeTransaction)
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by executeRuling():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when executing a ruled dispute where jurors refused to rule.', async () => {
      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveFinalRulingHelper(disputeID, DisputeRuling.RefusedToRule)

      const txPromise = contract
        .connect(other)
        .executeRuling(transactionId, disputeTransaction)
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by executeRuling():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when submitting evidence.', async () => {
      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )

      const txPromise = contract
        .connect(sender)
        .submitEvidence(transactionId, transaction, 'ipfs:/evidence_001')
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by submitEvidence():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when appealing one side (full funding).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise = contract
        .connect(receiver)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          { value: loserAppealFee }
        )
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when appealing one side (partial funding).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR

      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      const txPromise = contract
        .connect(crowdfunder1)
        .fundAppeal(
          transactionId,
          disputeTransaction,
          TransactionParty.Receiver,
          { value: loserAppealFee / 2 }
        )
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when appealing one side (full funding) and creating new round.', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        loserAppealFee,
        TransactionParty.Receiver
      )
      const [txPromise, tx, receipt] = await fundAppealHelper(
        transactionId,
        disputeTransaction,
        sender,
        winnerAppealFee,
        TransactionParty.Sender
      )

      console.log('')
      console.log('\tGas used by fundAppeal():  ' + parseInt(receipt.gasUsed))
    })

    it('Estimate gas cost when withdrawing one round (winner side).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR

      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      await giveRulingHelper(disputeID, DisputeRuling.Sender)

      // Fully fund the loser side
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        receiver,
        loserAppealFee,
        TransactionParty.Receiver
      )
      await fundAppealHelper(
        transactionId,
        disputeTransaction,
        sender,
        winnerAppealFee,
        TransactionParty.Sender
      )

      // Give and execute final ruling
      const appealDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      await giveFinalRulingHelper(
        appealDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        transactionId,
        disputeTransaction,
        other
      )

      const [txPromise, tx, receipt] = await withdrawHelper(
        senderAddress,
        transactionId,
        ruleTransaction,
        0,
        sender
      )

      console.log('')
      console.log(
        '\tGas used by withdrawFeesAndRewards():  ' + parseInt(receipt.gasUsed)
      )
    })

    it('Estimate gas cost when batch-withdrawing 5 rounds (winner side).', async () => {
      const loserAppealFee =
        arbitrationFee + (arbitrationFee * loserMultiplier) / MULTIPLIER_DIVISOR
      const winnerAppealFee =
        arbitrationFee +
        (arbitrationFee * winnerMultiplier) / MULTIPLIER_DIVISOR
      const roundsLength = 5

      const [_, transactionId, transaction] = await createTransactionHelper(
        amount
      )
      const [
        disputeID,
        disputeTransactionId,
        disputeTransaction
      ] = await createDisputeHelper(transactionId, transaction)

      let roundDisputeID
      roundDisputeID = disputeID
      for (var round_i = 0; round_i < roundsLength; round_i += 1) {
        await giveRulingHelper(roundDisputeID, DisputeRuling.Sender)
        // Fully fund both sides
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder1,
          loserAppealFee,
          TransactionParty.Receiver
        )
        await fundAppealHelper(
          transactionId,
          disputeTransaction,
          crowdfunder2,
          winnerAppealFee,
          TransactionParty.Sender
        )
        roundDisputeID = await arbitrator.getAppealDisputeID(disputeID)
      }

      // Give and execute final ruling
      await giveFinalRulingHelper(
        roundDisputeID,
        DisputeRuling.Sender,
        disputeID
      )
      const [ruleTransactionId, ruleTransaction] = await executeRulingHelper(
        transactionId,
        disputeTransaction,
        other
      )

      // Batch-withdraw (checking if _cursor and _count arguments are working as expected).
      const txPromise = contract
        .connect(other)
        .batchRoundWithdraw(
          await crowdfunder2.getAddress(),
          transactionId,
          ruleTransaction,
          0,
          0
        )
      const tx = await txPromise
      const receipt = await tx.wait()

      console.log('')
      console.log(
        '\tGas used by batchRoundWithdraw():  ' + parseInt(receipt.gasUsed)
      )
    })
  })

  async function createTransactionHelper(_amount) {
    const metaEvidence = metaEvidenceUri

    const tx = await contract
      .connect(sender)
      .createTransaction(
        amount,
        token.address,
        timeoutPayment,
        receiverAddress,
        metaEvidence
      )
    const receipt = await tx.wait()
    const [transactionId, transaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [receipt, transactionId, transaction]
  }

  async function createDisputeHelper(
    _transactionId,
    _transaction,
    fee = arbitrationFee
  ) {
    // Pay fees, create dispute and validate events.
    const receiverTxPromise = contract
      .connect(receiver)
      .payArbitrationFeeByReceiver(_transactionId, _transaction, {
        value: fee
      })
    const receiverFeeTx = await receiverTxPromise
    const receiverFeeReceipt = await receiverFeeTx.wait()
    expect(receiverTxPromise)
      .to.emit(contract, 'HasToPayFee')
      .withArgs(_transactionId, TransactionParty.Sender)
    const [receiverFeeTransactionId, receiverFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receiverFeeReceipt
    ).args
    const txPromise = contract
      .connect(sender)
      .payArbitrationFeeBySender(
        receiverFeeTransactionId,
        receiverFeeTransaction,
        {
          value: fee
        }
      )
    const senderFeeTx = await txPromise
    const senderFeeReceipt = await senderFeeTx.wait()
    const [senderFeeTransactionId, senderFeeTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      senderFeeReceipt
    ).args
    expect(txPromise)
      .to.emit(contract, 'Dispute')
      .withArgs(
        arbitrator.address,
        senderFeeTransaction.disputeID,
        senderFeeTransactionId,
        senderFeeTransactionId
      )
    expect(senderFeeTransaction.status).to.equal(
      TransactionStatus.DisputeCreated,
      'Invalid transaction status'
    )
    return [
      senderFeeTransaction.disputeID,
      senderFeeTransactionId,
      senderFeeTransaction
    ]
  }

  async function submitEvidenceHelper(
    transactionId,
    transaction,
    evidence,
    caller
  ) {
    const callerAddress = await caller.getAddress()
    if (
      callerAddress == transaction.sender ||
      callerAddress == transaction.receiver
    ) {
      if (transaction.status != TransactionStatus.Resolved) {
        const txPromise = contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
        const tx = await txPromise
        const receipt = await tx.wait()
        expect(txPromise)
          .to.emit(contract, 'Evidence')
          .withArgs(arbitrator.address, transactionId, callerAddress, evidence)
      } else {
        await expect(
          contract
            .connect(caller)
            .submitEvidence(transactionId, transaction, evidence)
        ).to.be.revertedWith(
          'Must not send evidence if the dispute is resolved.'
        )
      }
    } else {
      await expect(
        contract
          .connect(caller)
          .submitEvidence(transactionId, transaction, evidence)
      ).to.be.revertedWith('The caller must be the sender or the receiver.')
    }
  }

  async function giveRulingHelper(disputeID, ruling) {
    // Notice that rule() function is not called by the arbitrator, because the dispute is appealable.
    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  async function giveFinalRulingHelper(
    disputeID,
    ruling,
    transactionDisputeId = disputeID
  ) {
    const firstTx = await arbitrator.giveRuling(disputeID, ruling)
    await firstTx.wait()

    await increaseTime(appealTimeout + 1)

    const txPromise = arbitrator.giveRuling(disputeID, ruling)
    const tx = await txPromise
    const receipt = await tx.wait()

    expect(txPromise)
      .to.emit(contract, 'Ruling')
      .withArgs(arbitrator.address, transactionDisputeId, ruling)

    return [txPromise, tx, receipt]
  }

  async function executeRulingHelper(transactionId, transaction, caller) {
    const tx = await contract
      .connect(caller)
      .executeRuling(transactionId, transaction)
    const receipt = await tx.wait()
    const [newTransactionId, newTransaction] = getEmittedEvent(
      'TransactionStateUpdated',
      receipt
    ).args

    return [newTransactionId, newTransaction]
  }

  async function fundAppealHelper(
    transactionId,
    transaction,
    caller,
    contribution,
    side
  ) {
    const txPromise = contract
      .connect(caller)
      .fundAppeal(transactionId, transaction, side, { value: contribution })
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }

  async function withdrawHelper(
    beneficiary,
    transactionId,
    transaction,
    round,
    caller
  ) {
    const txPromise = contract
      .connect(caller)
      .withdrawFeesAndRewards(beneficiary, transactionId, transaction, round)
    const tx = await txPromise
    const receipt = await tx.wait()

    return [txPromise, tx, receipt]
  }
})
