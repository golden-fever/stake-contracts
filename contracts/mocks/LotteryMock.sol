/*
 * Copyright (c)
 */

pragma solidity 0.5.3;

import "../Lottery.sol";

contract LotteryMock is Lottery {
  
  constructor(CurrencyType _currencyType, address _currencyAddress, uint _roundDuration, uint _initialPayment, uint _lastWinnersCount, uint _memberSubtractRoundMultiplier) 
    public Lottery(_currencyType, _currencyAddress, _roundDuration, _initialPayment, _lastWinnersCount, _memberSubtractRoundMultiplier) {}
  
  function finishCurrentRound() public {
    LotteryRound storage _round = rounds[currentRoundNumber];
    _round.duration = _round.duration - getUntilCurrentRoundEnd();
  }
}
