global class getSmmarizePatientDetails {

    // =========================
    // REQUEST
    // =========================
    global class Request {       
        @InvocableVariable(required=true)
        global String AccountId;     
    }

    // =========================
    // RESPONSE
    // =========================
    global class promptResponse {

        // Only JSON output (clean)
        @InvocableVariable 
        global String Pacemaker_Data;
    }

    // ====================================================
    // INVOCABLE METHOD THIS METHOD USED FOR EMPLOYEE AGENT
    // ===================================================
    @InvocableMethod(
        label='Get Summarize Patient Details'
        description='Extract Patient and Telemetric details'
        category='Prompt'
    )
    global static List<promptResponse> invoke(List<Request> requests) {

        List<promptResponse> responses = new List<promptResponse>();

        if(requests == null || requests.isEmpty()){
            return responses;
        }

        // =========================
        // COLLECT ACCOUNT IDS
        // =========================
        Set<Id> accountIdSet = new Set<Id>();

        for(Request req : requests){
            if(req.AccountId != null){
                accountIdSet.add(req.AccountId);
            }
        }

        // =========================
        // CONTACT QUERY
        // =========================
        List<Contact> conList = [
            SELECT Name,Atrial_Risk_Score__c,
                   Pacing_Performance_Score__c,
                   Battery_Score__c,
                   Last_Transmission__c,
                   Cadence__c
            FROM Contact
            WHERE AccountId IN :accountIdSet 
            LIMIT 1
        ];

        // =========================
        // ASSET QUERY
        // =========================
        List<Asset> assetList = [
            SELECT SerialNumber, Implant_Site__c
            FROM Asset
            WHERE AccountId IN :accountIdSet
            AND SerialNumber != NULL
            LIMIT 1
        ];

        String serialNumber;

        if(!assetList.isEmpty()){
            serialNumber = assetList[0].SerialNumber;
        }

        // =========================
        // IOT DATA QUERY
        // =========================
        List<pacemaker_iot_data__dlm> iotDataList = new List<pacemaker_iot_data__dlm>();

        if(serialNumber != null){
            iotDataList = [
                SELECT AF_Burden__c,
                       Battery_Status__c,
                       Implant_Date__c,
                       Lower_Rate_Limit_bpm__c,
                       Manufacturer__c,
                       Product_Name__c,
                       Transmission_Status__c,
                       Transmission_Timestamp__c,
                       Upper_Tracking_Rate_bpm__c
                FROM pacemaker_iot_data__dlm
                WHERE Serial_Number__c = :serialNumber
                ORDER BY Transmission_Timestamp__c DESC
                LIMIT 10
            ];
        }

        // =========================
        // BUILD IOT ARRAY (ARRAY [])
        // =========================
        List<Map<String, Object>> iotArray = new List<Map<String, Object>>();

        for(pacemaker_iot_data__dlm data : iotDataList){

            Map<String, Object> recordMap = new Map<String, Object>{
                'AF_Burden' => data.AF_Burden__c,
                'Battery_Status' => data.Battery_Status__c,
                'Implant_Date' => data.Implant_Date__c,
                'Lower_Rate_Limit_bpm' => data.Lower_Rate_Limit_bpm__c,
                'Upper_Tracking_Rate_bpm' => data.Upper_Tracking_Rate_bpm__c,
                'Transmission_Time' => data.Transmission_Timestamp__c,
                'Transmission_Status' => data.Transmission_Status__c,
                'Manufacturer' => data.Manufacturer__c,
                'Product_Name' => data.Product_Name__c
            };

            iotArray.add(recordMap);
        }

        // =========================
        // BUILD FINAL CLEAN JSON
        // =========================
        Map<String, Object> finalPayload = new Map<String, Object>();

        // Patient
        if(!conList.isEmpty()){
            Contact con = conList[0];

            finalPayload.put('Patient', new Map<String, Object>{
                'Patient_Name' => con.Name,
                'Atrial_Risk_Score' => con.Atrial_Risk_Score__c,
                'Pacing_Performance_Score' => con.Pacing_Performance_Score__c,
                'Battery_Score' => con.Battery_Score__c,
                'Last_Transmission' => con.Last_Transmission__c,
                'Cadence' => con.Cadence__c
            });
        }

        // Device
        if(!assetList.isEmpty()){
            finalPayload.put('Device', new Map<String, Object>{
                'SerialNumber' => assetList[0].SerialNumber,
                'ImplantSite' => assetList[0].Implant_Site__c
            });
        }

        // SINGLE Pacemaker_Data ARRAY
        finalPayload.put('Pacemaker_Data', iotArray);

        // =========================
        // SERIALIZE JSON
        // =========================
        String jsonOutput = JSON.serializePretty(finalPayload);

        System.debug('## FINAL JSON = ' + jsonOutput);

        // =========================
        // RESPONSE
        // =========================
        promptResponse res = new promptResponse();
        res.Pacemaker_Data = jsonOutput;

        responses.add(res);

        return responses;
    }
}
