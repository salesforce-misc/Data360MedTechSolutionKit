global class getStructuredData { 

    global class Request {       
        @InvocableVariable(required=true)
        global String AccountId;     

        @InvocableVariable
        global String RequestType;
    }

    global class promptResponse {
        @InvocableVariable 
        global String Structured_Data;
    }

    @InvocableMethod(
        label='Get Structured Device Data'
        description='Handles multiple request types'
        category='Prompt'
    )
    global static List<promptResponse> invoke(List<Request> requests) {

        List<promptResponse> responses = new List<promptResponse>();
		System.debug('## requests = '+requests);
        try {

            if(requests == null || requests.isEmpty()){
                return responses;
            }

            Request req = requests[0];
			System.debug('## req = '+req);
            System.debug('## req AccountId = '+req.AccountId);
            System.debug('## req.RequestType = '+req.RequestType);
            if(req.AccountId == null){
                return responses;
            }

            // IF REQUEST TYPE NOT PROVIDED → RETURN BLANK
            if(String.isBlank(req.RequestType)){
                return responses;
            }

            String requestType = req.RequestType.trim().toLowerCase();

            // =========================
            // COMMON CONTACT FETCH
            // =========================
            List<Contact> conList = [
                SELECT Id, Name,AccountId
                FROM Contact
                WHERE ( AccountId = :req.AccountId OR Id = :req.AccountId) and Implant_Date__c != NULL
                LIMIT 1
            ];
			
            if(conList.isEmpty()){
                return responses;
            }

            Contact con = conList[0];
            Id contactId = con.Id;
			Id accountId = con.AccountId;
            Map<String, Object> finalPayload = new Map<String, Object>();

            Map<String, Object> patientMap = new Map<String, Object>{
                'Patient_Name' => con.Name
            };

            finalPayload.put('Patient', patientMap);

            if(requestType == 'HomeMonitor'){

                List<ssot__Asset__dlm> assetList = [
                    SELECT ssot__ProductId__c
                    FROM ssot__Asset__dlm
                    WHERE ssot__PrimaryContactId__c = :contactId
                    AND ssot__ProductId__c != NULL
                ];

                Set<Id> productIds = new Set<Id>();

                for(ssot__Asset__dlm asset : assetList){
                    if(asset.ssot__ProductId__c != null){
                        productIds.add(asset.ssot__ProductId__c);
                    }
                }

                List<ssot__Product__dlm> productDataList = new List<ssot__Product__dlm>();

                if(!productIds.isEmpty()){
                    productDataList = [
                        SELECT Device_Type__c,
                               OS_Version__c,
                               ssot__ProductCode__c,
                               ssot__ProductFamily__c,ssot__Name__c 
                        FROM ssot__Product__dlm
                        WHERE ssot__IsActive__c = 'true'
                        AND ssot__ProductFamily__c = 'Remote Monitor'
                        AND ssot__Id__c IN :productIds
                    ];
                }

                List<Map<String, Object>> monitorArray = new List<Map<String, Object>>();

                for(ssot__Product__dlm data : productDataList){
                    monitorArray.add(new Map<String, Object>{
                        'Device_Type' => data.Device_Type__c,
                        'OS_Version' => data.OS_Version__c,
                        'Monitor_Modal' => data.ssot__ProductCode__c,
                        'Product_Name' => data.ssot__Name__c
                    });
                }

                finalPayload.put('Home_Monitor', monitorArray);
            }

            else if(requestType == 'WarrantyCoverage'){ 

                List<ssot__Asset__dlm> assetList = [
                    SELECT ssot__Id__c, ssot__ProductId__c
                    FROM ssot__Asset__dlm
                    WHERE ssot__PrimaryContactId__c = :contactId
                    AND ssot__ProductId__c != NULL
                ];
            
                Set<Id> productIds = new Set<Id>();
                Map<Id, Id> assetToProductMap = new Map<Id, Id>();
            
                for(ssot__Asset__dlm asset : assetList){
                    if(asset.ssot__ProductId__c != null){
                        productIds.add(asset.ssot__ProductId__c);
                        assetToProductMap.put(asset.ssot__Id__c, asset.ssot__ProductId__c);
                    }
                }
            
                // =========================
                // PRODUCT QUERY
                // =========================
                List<ssot__Product__dlm> productDataList = new List<ssot__Product__dlm>();
            
                if(!productIds.isEmpty()){
                    productDataList = [
                        SELECT ssot__Id__c,
                               ssot__ProductCode__c,
                               ssot__Name__c
                        FROM ssot__Product__dlm
                        WHERE ssot__IsActive__c = 'true'
                        AND ssot__ProductFamily__c = 'Remote Monitor'
                        AND ssot__Id__c IN :productIds
                    ];
                }
            
                Map<Id, ssot__Product__dlm> productMap = new Map<Id, ssot__Product__dlm>();
                for(ssot__Product__dlm p : productDataList){
                    productMap.put(p.ssot__Id__c, p);
                }
            
                // =========================
                // BUILD PRODUCT DATA
                // =========================
                List<Map<String, Object>> productMapList = new List<Map<String, Object>>();
                Set<Id> assetIds = new Set<Id>();
            	if(!assetList.isEmpty()){
                    for(ssot__Asset__dlm asset : assetList){
                        if(productMap.containsKey(asset.ssot__ProductId__c)){
                            ssot__Product__dlm prod = productMap.get(asset.ssot__ProductId__c);
                			assetIds.add(asset.ssot__Id__c);
                            productMapList.add(new Map<String, Object>{
                                'Product_Name' => prod.ssot__Name__c
                            });
                        }
                    }
                }
            
                finalPayload.put('Product_Data', productMapList);
            
                // =========================
                // ENTITLEMENT QUERY (CORRECTED)
                // =========================
                List<Map<String, Object>> entitlementMapList = new List<Map<String, Object>>();
            
                if(assetIds != NULL){            
            
                    List<Entitlement_Home__dlm> entitlementList = [
                        SELECT AssetId__c, StartDate__c, EndDate__c
                        FROM Entitlement_Home__dlm
                        WHERE AccountId__c = :accountId
                        AND AssetId__c IN :assetIds
                    ];
            
                    for(Entitlement_Home__dlm ent : entitlementList){
            
                        String isProductUnderWarranty = 
                            (ent.StartDate__c <= Date.today() && ent.EndDate__c >= Date.today())
                            ? 'Product Cover With Warranty'
                            : 'Product Not Cover With Warranty';
            
                        entitlementMapList.add(new Map<String, Object>{
                            'Start_Date' => ent.StartDate__c,
                            'End_Date' => ent.EndDate__c,
                            'Is_Product_Under_Warranty' => isProductUnderWarranty
                        });
                    }
                }
            
                finalPayload.put('Entitlement_Data', entitlementMapList);
            }
            else if(requestType == 'MonitorTransmitting'){ 
                List<Asset> assetList = [
                    SELECT SerialNumber, Implant_Site__c
                    FROM Asset
                    WHERE AccountId =: accountId
                    AND SerialNumber != NULL
                    LIMIT 1 
                ];
        
                String serialNumber;
        
                if(!assetList.isEmpty()){
                    serialNumber = assetList[0].SerialNumber;
                }
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
                
                List<Map<String, Object>> iotArray = new List<Map<String, Object>>();

                for(pacemaker_iot_data__dlm data : iotDataList){
        
                    Map<String, Object> recordMap = new Map<String, Object>{
                        'Battery_Status' => data.Battery_Status__c,
                        'Implant_Date' => data.Implant_Date__c,
                        'Transmission_Time' => data.Transmission_Timestamp__c,
                        'Transmission_Status' => data.Transmission_Status__c,
                        'Manufacturer' => data.Manufacturer__c,
                        'Product_Name' => data.Product_Name__c
                    };
        
                    iotArray.add(recordMap);
                }
                finalPayload.put('Telemetry_Data', iotArray);
            }
            else if(requestType == 'SummarizePrimaryCareDoctor'){
                List<Asset> assetList = [
                    SELECT SerialNumber, Implant_Site__c
                    FROM Asset
                    WHERE AccountId =: accountId
                    AND SerialNumber != NULL
                    LIMIT 1 
                ];
        
                String serialNumber;
        
                if(!assetList.isEmpty()){
                    serialNumber = assetList[0].SerialNumber;
                }
                List<pacemaker_iot_data__dlm> iotDataList = new List<pacemaker_iot_data__dlm>();

                if(serialNumber != null){
                    iotDataList = [
                        SELECT Transmission_Timestamp__c,
                        Episode_Duration_s__c,Episode_Timestamp__c,Episode_Type__c,
                        Atrial_Capture_Status__c,Atrial_Lead_Impedance_Ohms__c,Atrial_Pacing_Percentage__c,
                        Atrial_Pacing_Threshold_V__c,Atrial_Sensing_Amplitude_mV__c,
                        Product_Name__c,
                        Ventricular_Capture_Status__c,Ventricular_Lead_Impedance_Ohms__c,
                        Ventricular_Pacing_Percentage__c,Ventricular_Pacing_Threshold_V__c,
                        Ventricular_Sensing_Amplitude_mV__c
                        FROM pacemaker_iot_data__dlm
                        WHERE Serial_Number__c = :serialNumber
                        ORDER BY Transmission_Timestamp__c DESC
                        LIMIT 10
                    ];
                }
                
                List<Map<String, Object>> iotArray = new List<Map<String, Object>>();

                for(pacemaker_iot_data__dlm data : iotDataList){
        
                    Map<String, Object> recordMap = new Map<String, Object>{
                        'Episode_Duration' => data.Episode_Duration_s__c,
                        'Episode_Timestamp' => data.Episode_Timestamp__c,
                        'Episode_Type' => data.Episode_Type__c,
                        'Atrial_Capture_Status' => data.Atrial_Capture_Status__c,
                        'Atrial_Lead_Impedance_Ohms' => data.Atrial_Lead_Impedance_Ohms__c,
                        'Atrial_Pacing_Percentage' => data.Atrial_Pacing_Percentage__c,
						'Atrial_Pacing_Threshold_V' => data.Atrial_Pacing_Threshold_V__c,
						'Atrial_Sensing_Amplitude_mV' => data.Atrial_Sensing_Amplitude_mV__c,
						'Product_Name' => data.Product_Name__c,
						'Ventricular_Capture_Status' => data.Ventricular_Capture_Status__c,
						'Ventricular_Lead_Impedance_Ohms' => data.Ventricular_Lead_Impedance_Ohms__c,
						'Ventricular_Pacing_Percentage' => data.Ventricular_Pacing_Percentage__c,
						'Ventricular_Pacing_Threshold_V' => data.Ventricular_Pacing_Threshold_V__c,
						'Ventricular_Sensing_Amplitude_mV' => data.Ventricular_Sensing_Amplitude_mV__c
                    };
        
                    iotArray.add(recordMap);
                }
                finalPayload.put('Telemetry_Data', iotArray);
                
                List<ssot__Case__dlm> caseList = [SELECT ssot__Subject__c,ssot__CaseStatusId__c FROM ssot__Case__dlm where ssot__AccountContactId__c =: contactId];
                if(!caseList.isEmpty()){
                    List<Map<String, Object>> caseArray = new List<Map<String, Object>>();
					Integer counter = 1;
                    for(ssot__Case__dlm caseData : caseList){            
                        Map<String, Object> recordMap = new Map<String, Object>{
                            ('Case_' + counter + '_Status') => caseData.ssot__CaseStatusId__c,
                            'Case_Subject' => caseData.ssot__Subject__c                            
                        };
            			counter++;
                        caseArray.add(recordMap);
                    }
                    
                    finalPayload.put('Case_History_Data', caseArray);
                    
                    }
            }
            if(!finalPayload.isEmpty()){

                String jsonOutput = JSON.serializePretty(finalPayload);

                System.debug('## FINAL JSON = ' + jsonOutput);

                promptResponse res = new promptResponse();
                res.Structured_Data = jsonOutput;

                responses.add(res);
            }

        } catch (Exception e) {

            System.debug('## ERROR: ' + e.getMessage());

            promptResponse res = new promptResponse();
            res.Structured_Data = JSON.serializePretty(new Map<String, Object>{
                'error' => true,
                'message' => 'Unable to fetch Home Monitor data'
            });

            responses.add(res);
        }

        return responses;
    }  
}
