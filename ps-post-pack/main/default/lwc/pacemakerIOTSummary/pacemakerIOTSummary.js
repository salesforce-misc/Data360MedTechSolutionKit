import { LightningElement, api, wire } from 'lwc';
import getAccountDetails from '@salesforce/apex/GetAccounts.getAccountDetails';

export default class PacemakerIOTSummary extends LightningElement {

    @api recordId;

    @wire(getAccountDetails, { accountId: '$recordId' })
    account;

    get contact(){
        return this.account?.data?.Contacts?.[0];
    }

    /* Last Transmission */

    get Last_Transmission(){
        //return '2026-03-07T09:57:06.000+0000';
         return this.contact?.Last_Transmission__c;
    }

    get formattedLastTransmission(){

        const value = this.Last_Transmission;

        if(!value){
            return '';
        }

        const date = new Date(value);
        const day = String(date.getDate()).padStart(2,'0');
        const month = String(date.getMonth() + 1).padStart(2,'0');
        const year = date.getFullYear();

        return `${day}-${month}-${year}`;
        //return date.toLocaleString();
    }

    /* Cadence */

    get cadence(){
        return this.contact?.Cadence__c;
    }

    /* Battery */

    get Battery_Score(){

        const value = this.contact?.Battery_Score__c;

        return (value || value === 0)
            ? (Math.round(value * 100) / 100)
            : '25';
    }

    /* Atrial Risk */

    get Atrial_Risk_Score(){

        const value = this.contact?.Atrial_Risk_Score__c;

        if(value === 1) return 'No Arrythmia Detected';
        if(value === 2) return 'Arrythmis Needs Monitoring';
        if(value === 3) return 'Serious Arrytmis Detected';

        return '';
    }

    get atrialRiskClass(){

        const value = this.contact?.Atrial_Risk_Score__c;

        if(value === 1){
            return 'value-text greenText';
        }

        if(value === 2 || value === 3){
            return 'value-text redText';
        }

        return 'value-text';
    }

    /* Pacing Performance */

    get Pacing_Performance_Score(){

        const value = this.contact?.Pacing_Performance_Score__c;

        if(value === 1) return 'Device Needs Attention';
        if(value === 2) return 'Device Needs Monitoring';
        if(value === 3) return 'Device Working Well';

        return '';
    }

    get pacingClass(){

        const value = this.contact?.Pacing_Performance_Score__c;

        if(value === 3){
            return 'value-text greenText';
        }

        if(value === 1 || value === 2){
            return 'value-text redText';
        }

        return 'value-text';
    }

    /* Transmission */

    get daysSinceTransmission(){

        const last = this.Last_Transmission;

        if(!last){
            return null;
        }

        const today = new Date();
        const lastTransmission = new Date(last);

        const diffTime = today.getTime() - lastTransmission.getTime();

        return Math.floor(diffTime / (1000 * 60 * 60 * 24));
    }

    get transmissionStatus(){

        const cadence = this.cadence;
        const days = this.daysSinceTransmission;

        if(days === null || !cadence){
            return '';
        }

        if(days > cadence){
            return 'Transmission Delayed';
        }

        return 'On-Time Transmission';
    }

    get transmissionClass(){

        const cadence = this.cadence;
        const days = this.daysSinceTransmission;

        if(days === null || !cadence){
            return '';
        }

        if(days > cadence){
            return 'status redBackground';
        }

        return 'status greenBackground';
    }

    /*
    Pacemaker Patient Health Summary
    ====================================
    SELECT UnifiedssotIndividualProd__dlm.ssot__Id__c AS unifiedindividualid__c, /Battery Health Score / SUM( CASE WHEN pacemaker_iot_data__dlm.Battery_Voltage__c >= 2.9 THEN 100 WHEN pacemaker_iot_data__dlm.Battery_Voltage__c >= 2.7 THEN 50 ELSE 0 END ) / COUNT(pacemaker_iot_data__dlm.Transmission_Timestamp__c) AS battery_score__c, / Pacing Performance Score / SUM( CASE WHEN pacemaker_iot_data__dlm.Atrial_Capture_Status__c = 'Stable' AND pacemaker_iot_data__dlm.Ventricular_Capture_Status__c = 'Stable' AND pacemaker_iot_data__dlm.Atrial_Pacing_Threshold_V__c < 2.5 AND pacemaker_iot_data__dlm.Ventricular_Pacing_Threshold_V__c < 2.5 THEN 3 WHEN pacemaker_iot_data__dlm.Atrial_Capture_Status__c = 'Stable' AND pacemaker_iot_data__dlm.Ventricular_Capture_Status__c = 'Stable' AND ( pacemaker_iot_data__dlm.Atrial_Pacing_Threshold_V__c >= 2.5 OR pacemaker_iot_data__dlm.Ventricular_Pacing_Threshold_V__c >= 2.5 ) THEN 2 ELSE 1 END ) / COUNT(pacemaker_iot_data__dlm.Transmission_Timestamp__c) AS pacing_performance_score__c, / AF Risk Score / SUM( CASE WHEN pacemaker_iot_data__dlm.AF_Burden__c = 0 AND pacemaker_iot_data__dlm.VT_Episodes__c = 0 AND pacemaker_iot_data__dlm.VF_Episodes__c = 0 THEN 1 WHEN ( pacemaker_iot_data__dlm.AF_Burden__c > 0 AND pacemaker_iot_data__dlm.AF_Burden__c <= 10 ) OR pacemaker_iot_data__dlm.Episode_Duration_s__c > 0 THEN 2 ELSE 3 END ) / COUNT(pacemaker_iot_data__dlm.Transmission_Timestamp__c) AS af_risk_score__c FROM pacemaker_iot_data__dlm JOIN Pacemaker_Latest_Transmission__cio ON pacemaker_iot_data__dlm.Serial_Number__c = Pacemaker_Latest_Transmission__cio.serial_number__c AND pacemaker_iot_data__dlm.Transmission_Timestamp__c = Pacemaker_Latest_Transmission__cio.latest_ts__c JOIN ssot__Asset__dlm ON pacemaker_iot_data__dlm.Serial_Number__c = ssot__Asset__dlm.ssot__SerialNumber__c JOIN UnifiedLinkssotIndividualProd__dlm ON ssot__Asset__dlm.ssot__PrimaryContactId__c = UnifiedLinkssotIndividualProd__dlm.SourceRecordId__c JOIN UnifiedssotIndividualProd__dlm ON UnifiedLinkssotIndividualProd__dlm.UnifiedRecordId__c = UnifiedssotIndividualProd__dlm.ssot__Id__c GROUP BY UnifiedssotIndividualProd__dlm.ssot__Id__c


    Pacemaker Latest Transmission
    ===================================
    SELECT pacemaker_iot_data__dlm.Serial_Number__c AS serial_number__c, MAX(pacemaker_iot_data__dlm.Transmission_Timestamp__c) AS latest_ts__c FROM pacemaker_iot_data__dlm GROUP BY pacemaker_iot_data__dlm.Serial_Number__c



    */

}