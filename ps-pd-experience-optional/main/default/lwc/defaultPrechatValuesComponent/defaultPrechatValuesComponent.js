import { LightningElement, wire } from 'lwc';
import USER_ID from '@salesforce/user/Id';
import { getRecord } from 'lightning/uiRecordApi';

const USER_FIELDS = ['User.ContactId'];
export default class DefaultPrechatValuesComponent extends LightningElement {
	userDetails;
    //eventDispatched = false;

    @wire(getRecord, { recordId: USER_ID, fields: USER_FIELDS })
    userDataHandler({ data, error }) {
        if (data) {

            this.userDetails = {
                userId: USER_ID,
                contactId: data.fields.ContactId?.value || null
            };

            const userDetailsEvent = new CustomEvent('userDetails', {
                detail: this.userDetails,
                bubbles: true,
                composed: true
            });

            this.dispatchEvent(userDetailsEvent);
            //this.eventDispatched = true;

            console.log('User context dispatched:', this.userDetails);

        } else if (error) {
            console.error('Error retrieving user context', error);
        }
    }
}