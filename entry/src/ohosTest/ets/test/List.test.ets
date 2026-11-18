import logicTest from './Logic.test';
import userJourneyTest from './UserJourney.test';
import connectJourneyTest from './ConnectJourney.test';
import workspaceJourneyTest from './WorkspaceJourney.test';

export default function testsuite() {
  logicTest();
  userJourneyTest();
  workspaceJourneyTest();
  connectJourneyTest();
}
