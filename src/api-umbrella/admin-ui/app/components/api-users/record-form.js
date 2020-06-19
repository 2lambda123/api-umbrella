import Component from '@ember/component';
import Save from 'api-umbrella-admin-ui/mixins/save';
import escape from 'lodash-es/escape';
import { t } from 'api-umbrella-admin-ui/utils/i18n';

export default Component.extend(Save, {
  init() {
    this._super(...arguments);

    this.throttleByIpOptions = [
      { id: false, name: 'Rate limit by API key' },
      { id: true, name: 'Rate limit by IP address' },
    ];

    this.enabledOptions = [
      { id: true, name: 'Enabled' },
      { id: false, name: 'Disabled' },
    ];
  },

  actions: {
    apiKeyRevealToggle() {
      let $key = this.$().find('.api-key');
      let $toggle = this.$().find('.api-key-reveal-toggle');

      if($key.data('revealed') === 'true') {
        $key.text($key.data('api-key-preview'));
        $key.data('revealed', 'false');
        $toggle.text(t('(reveal)'));
      } else {
        $key.text($key.data('api-key'));
        $key.data('revealed', 'true');
        $toggle.text(t('(hide)'));
      }
    },

    submit() {
      const isNew = this.model.get('isNew');
      this.saveRecord({
        transitionToRoute: 'api_users',
        message(model) {
          let message = '<p>Successfully saved the user "' + escape(model.get('email')) + '"</p>';
          if(isNew && model.get('apiKey')) {
            message += '<p style="font-size: 18px;"><strong>API Key:</strong> <code>' + escape(model.get('apiKey')) + '</code></p>';
            message += '<p><strong>Note:</strong> This API key will not be displayed again, so make note of it if needed.</p>';
          }

          return message;
        },
        messageHide(model) {
          if(isNew && model.get('apiKey')) {
            return false;
          } else {
            return true;
          }
        },
        messageWidth(model) {
          if(isNew && model.get('apiKey')) {
            return '500px';
          } else {
            return undefined;
          }
        },
      });
    },
  },
});
