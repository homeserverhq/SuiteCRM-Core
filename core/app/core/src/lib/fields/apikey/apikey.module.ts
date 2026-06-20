import {CUSTOM_ELEMENTS_SCHEMA, NgModule} from '@angular/core';
import {CommonModule} from '@angular/common';
import {FormsModule} from '@angular/forms';
import {ApikeyEditFieldComponent} from './templates/edit/apikey.component';
import {ApikeyDetailFieldComponent} from './templates/detail/apikey.component';

@NgModule({
    declarations: [
        ApikeyEditFieldComponent,
        ApikeyDetailFieldComponent,
    ],
    exports: [
        ApikeyEditFieldComponent,
        ApikeyDetailFieldComponent,
    ],
    imports: [
        CommonModule,
        FormsModule,
    ],
    schemas: [CUSTOM_ELEMENTS_SCHEMA]
})
export class ApikeyFieldModule {
}
