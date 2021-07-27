// eslint-disable-next-line ember/no-classic-components
import Component from '@ember/component';
import { action } from '@ember/object';
import { tagName } from '@ember-decorators/component';
// eslint-disable-next-line ember/no-mixins
import Save from 'api-umbrella-admin-ui/mixins/save';
import classic from 'ember-classic-decorator';
import escape from 'lodash-es/escape';

@classic
@tagName("")
export default class RecordForm extends Component.extend(Save) {
  @action
  submitForm() {
    this.saveRecord({
      transitionToRoute: 'api_scopes',
      message: 'Successfully saved the API scope "' + escape(this.model.name) + '"',
    });
  }

  @action
  delete() {
    this.destroyRecord({
      prompt: 'Are you sure you want to delete the API scope "' + escape(this.model.name) + '"?',
      transitionToRoute: 'api_scopes',
      message: 'Successfully deleted the API scope "' + escape(this.model.name) + '"',
    });
  }
}
