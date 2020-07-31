import config from '../config/environment';
import { defaultStack } from '@pnotify/core';

export function initialize() {
  if(config.integrationTestMode === true) {
    // Export the removeAll function as a global, for use in our test suite.
    window.PNotifyRemoveAll = defaultStack.close;
  }
}

export default {
  name: 'test-pnotify',
  initialize,
};
