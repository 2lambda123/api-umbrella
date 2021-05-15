// eslint-disable-next-line ember/no-classic-components
import Component from '@ember/component';
import { computed } from '@ember/object';
import { observes } from '@ember-decorators/object';
import classic from 'ember-classic-decorator';
import $ from 'jquery';
import clone from 'lodash-es/clone';
import escape from 'lodash-es/escape';
import numeral from 'numeral';

// eslint-disable-next-line ember/no-classic-classes
@classic
export default class ResultsTable extends Component {
  didInsertElement() {
    super.didInsertElement(...arguments);
    this.$().find('table').DataTable({
      searching: false,
      order: [[1, 'desc']],
      data: this.regions,
      columns: [
        {
          data: 'name',
          title: 'Location',
          defaultContent: '-',
          render: (name, type, data) => {
            if(type === 'display' && name && name !== '-') {
              let link;
              let params = clone(this.presentQueryParamValues);
              if(this.regionField === 'request_ip_city') {
                delete params.region;
                params.search = 'request_ip_city:"' + data.id + '"';
                link = '#/stats/logs?' + $.param(params);
              } else {
                params.region = data.id;
                link = '#/stats/map?' + $.param(params);
              }

              return '<a href="' + link + '">' + escape(name) + '</a>';
            }

            return name;
          },
        },
        {
          data: 'hits',
          title: 'Hits',
          defaultContent: '-',
          render(number, type) {
            if(type === 'display' && number && number !== '-') {
              return numeral(number).format('0,0');
            }

            return number;
          },
        },
      ],
    });
  }

  // eslint-disable-next-line ember/no-observers
  @observes('regions')
  refreshData() {
    let table = this.$().find('table').dataTable().api();
    table.clear();
    table.rows.add(this.regions);
    table.draw();
  }

  @computed('backendQueryParamValues')
  get downloadUrl() {
    return '/admin/stats/map.csv?' + $.param(this.backendQueryParamValues);
  }
}
