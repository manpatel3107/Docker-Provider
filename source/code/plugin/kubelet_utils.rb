# Copyright (c) Microsoft Corporation.  All rights reserved.
#!/usr/local/bin/ruby
# frozen_string_literal: true

require_relative 'CAdvisorMetricsAPIClient'

class KubeletUtils
    class << self
        def get_node_capacity
            
            cpu_capacity = 1.0
            memory_capacity = 1.0

            response = CAdvisorMetricsAPIClient.getNodeCapacityFromCAdvisor(winNode: nil)
            if !response.nil? && !response.body.nil?
                cpu_capacity = JSON.parse(response.body)["num_cores"].nil? ? 1.0 : (JSON.parse(response.body)["num_cores"] * 1000.0)
                memory_capacity = JSON.parse(response.body)["memory_capacity"].nil? ? 1.0 : JSON.parse(response.body)["memory_capacity"].to_f
                $log.info "CPU = #{cpu_capacity}mc Memory = #{memory_capacity/1024/1024}MB"
                return [cpu_capacity, memory_capacity]
            end
        end

        def getContainerInventoryRecords(batchTime, clusterCollectEnvironmentVar)    
            containerInventoryRecords = Array.new                   
            begin
                response = CAdvisorMetricsAPIClient.getPodsFromCAdvisor(winNode: nil)
                if !response.nil? && !response.body.nil?
                    podList = JSON.parse(response.body)
                    if !podList.nil? && !podList.empty? && podList.key?("items") && !podList["items"].nil? && !podList["items"].empty?
                        podList["items"].each do |item|
                            containersInfoMap = getContainersInfoMap(item, clusterCollectEnvironmentVar)
                            containerInventoryRecord = {}                                                                                          
                            if !item["status"].nil? && !item["status"].empty?                              
                                if !item["status"]["containerStatuses"].nil? && !item["status"]["containerStatuses"].empty?
                                    item["status"]["containerStatuses"].each do |containerStatus| 
                                     containerInventoryRecord["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated    
                                     containerName = containerStatus["name"]    
                                     containerInventoryRecord["ContainerID"] = containerStatus["containerID"].split('//')[1]
                                     repoImageTagArray = containerStatus["image"].split("/")
                                     containerInventoryRecord["Repository"] = repoImageTagArray[0]
                                     imageTagArray = repoImageTagArray[1].split(":")
                                     containerInventoryRecord["Image"] = imageTagArray[0]
                                     containerInventoryRecord["ImageTag"] = imageTagArray[1]
                                     # Setting the image id to the id in the remote repository
                                     containerInventoryRecord["ImageId"] = containerStatus["imageID"].split("@")[1]
                                     containerInfoMap = containersInfoMap[containerName]  
                                     containerInventoryRecord["ElementName"] = containerInfoMap["ElementName"]
                                     containerInventoryRecord["Computer"] = containerInfoMap["Computer"]
                                     containerInventoryRecord["ContainerHostname"] = containerInfoMap["ContainerHostname"]
                                     containerInventoryRecord["CreatedTime"] = containerInfoMap["CreatedTime"]
                                     containerInventoryRecord["EnvironmentVar"] = containerInfoMap["EnvironmentVar"]
                                     containerInventoryRecord["Ports"] = containerInfoMap["Ports"]
                                     containerInventoryRecord["Command"] = containerInfoMap["Command"]
                                     containerInventoryRecords.push containerInventoryRecord
                                    end
                                end 
                            end                                                      
                        end    
                    end
                end
            rescue => error
                @Log.warn("kubelet_utils::getContainerInventoryRecords : Get Container Inventory Records failed: #{error}")
            end          
            return containerInventoryRecords
        end

        def getContainersInfoMap(item, clusterCollectEnvironmentVar)
            containersInfoMap = {}
            begin
                nodeName = (!item["spec"]["nodeName"].nil?) ? item["spec"]["nodeName"] : ""                
                createdTime = item["metadata"]["creationTimestamp"]    
                if !item.nil? && !item.empty? && item.key?("spec") && !item["spec"].nil? && !item["spec"].empty?   
                    if !item["spec"]["containers"].nil? && !item["spec"]["containers"].empty?
                        item["spec"]["containers"].each do |container|
                            containerInfoMap = {}
                            containerName = container["name"]    
                            containerInfoMap["ElementName"] = containerName
                            containerInfoMap["Computer"] = nodeName             
                            containerInfoMap["ContainerHostname"] = nodeName
                            containerInfoMap["CreatedTime"] = createdTime

                            if !clusterCollectEnvironmentVar.nil? && !clusterCollectEnvironmentVar.empty? && clusterCollectEnvironmentVar.casecmp("false") == 0
                                containerInfoMap["EnvironmentVar"] = ["AZMON_CLUSTER_COLLECT_ENV_VAR=FALSE"]
                            else
                                envValue = container["env"]
                                envValueString = (envValue.nil?) ? "" : envValue.to_s
                                # Skip environment variable processing if it contains the flag AZMON_COLLECT_ENV=FALSE
                                # Check to see if the environment variable collection is disabled for this container.
                                if /AZMON_COLLECT_ENV=FALSE/i.match(envValueString)
                                envValueString = ["AZMON_COLLECT_ENV=FALSE"]
                                $log.warn("Environment Variable collection for container: #{containerName} skipped because AZMON_COLLECT_ENV is set to false")
                                end
                                # Restricting the ENV string value to 200kb since the size of this string can go very high
                                if envValueString.length > 200000
                                    envValueStringTruncated = envValueString.slice(0..200000)
                                    lastIndex = envValueStringTruncated.rindex("\", ")
                                    if !lastIndex.nil?
                                        envValueStringTruncated = envValueStringTruncated.slice(0..lastIndex) + "]"
                                    end
                                    containerInfoMap["EnvironmentVar"] = envValueStringTruncated
                                else
                                    containerInfoMap["EnvironmentVar"] = envValueString
                                end
                            end              
                            portsValue = container["ports"]
                            portsValueString = (portsValue.nil?) ? "" : portsValue.to_s     
                            containerInfoMap["Ports"] = portsValueString    
                            argsValue = container["args"]
                            argsValueString = (argsValue.nil?) ? "" : argsValue.to_s     
                            containerInfoMap["Command"] = argsValueString

                            containersInfoMap[containerName] = containerInfoMap         
                        end    
                    end
                end                 
            rescue => error      
                @Log.warn("kubelet_utils::getContainersInfoMap : Get Container Info Maps failed: #{error}")          
            end
            return containersInfoMap
        end  
    end
end