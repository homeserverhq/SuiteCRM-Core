import {Component} from '@angular/core';
import {BaseFieldComponent} from '../../../base/base-field.component';
import {DataTypeFormatter} from '../../../../services/formatters/data-type.formatter.service';
import {FieldLogicManager} from '../../../field-logic/field-logic.manager';
import {FieldLogicDisplayManager} from '../../../field-logic-display/field-logic-display.manager';
import {HttpClient} from '@angular/common/http';

@Component({
    selector: 'scrm-apikey-detail',
    templateUrl: './apikey.component.html',
    styleUrls: []
})
export class ApikeyDetailFieldComponent extends BaseFieldComponent {

    constructor(
        protected typeFormatter: DataTypeFormatter,
        protected logic: FieldLogicManager,
        protected logicDisplay: FieldLogicDisplayManager,
        protected http: HttpClient
    ) {
        super(typeFormatter, logic, logicDisplay);
    }

    generateKey(): void {
        this.http.post<{api_key: string}>('/api/key/generate', {}).subscribe({
            next: (response) => {
                if (this.field) {
                    this.field.value = response.api_key;
                }
            }
        });
    }

    copyKey(): void {
        if (this.field?.value) {
            navigator.clipboard.writeText(this.field.value);
        }
    }
}
