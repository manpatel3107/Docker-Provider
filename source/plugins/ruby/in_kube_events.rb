#!/usr/local/bin/ruby
# frozen_string_literal: true

module Fluent
  class Kube_Event_Input < Input
    Plugin.register_input("kubeevents", self)
    @@KubeEventsStateFile = "/var/opt/microsoft/docker-cimprov/state/KubeEventQueryState.yaml"

    def initialize
      super
      require "yajl/json_gem"
      require "yajl"
      require "time"

      require_relative "KubernetesApiClient"
      require_relative "oms_common"
      require_relative "omslog"
      require_relative "ApplicationInsightsUtility"

      # 30000 events account to approximately 5MB
      @EVENTS_CHUNK_SIZE = 30000

      @EVENTS_EMIT_STREAM = true

      # Initializing events count for telemetry
      @eventsCount = 0

      # Initilize enable/disable normal event collection
      @collectAllKubeEvents =

        @ENABLE_PARSE_AND_EMIT = true
    end

    config_param :run_interval, :time, :default => 60
    config_param :tag, :string, :default => "oms.containerinsights.KubeEvents"

    def configure(conf)
      super
    end

    def start
      if @run_interval
        if !ENV["EVENTS_CHUNK_SIZE"].nil? && !ENV["EVENTS_CHUNK_SIZE"].empty?
          @EVENTS_CHUNK_SIZE = ENV["EVENTS_CHUNK_SIZE"]
        end
        $log.info("in_kube_events::start : EVENTS_CHUNK_SIZE  @ #{@EVENTS_CHUNK_SIZE}")

        if !ENV["EVENTS_EMIT_STREAM"].nil? && !ENV["EVENTS_EMIT_STREAM"].empty?
          @EVENTS_EMIT_STREAM = ENV["EVENTS_EMIT_STREAM"].to_s.downcase == "true" ? true : false
        end
        $log.info("in_kube_events::start : EVENTS_EMIT_STREAM  @ #{@EVENTS_EMIT_STREAM}")

        if !ENV["ENABLE_PARSE_AND_EMIT"].nil? && !ENV["ENABLE_PARSE_AND_EMIT"].empty?
          @ENABLE_PARSE_AND_EMIT = ENV["ENABLE_PARSE_AND_EMIT"].to_s.downcase == "true" ? true : false
        end
        $log.info("in_kube_podinventory::start : ENABLE_PARSE_AND_EMIT  @ #{@ENABLE_PARSE_AND_EMIT}")

        @finished = false
        @condition = ConditionVariable.new
        @mutex = Mutex.new
        @thread = Thread.new(&method(:run_periodic))
        collectAllKubeEventsSetting = ENV["AZMON_CLUSTER_COLLECT_ALL_KUBE_EVENTS"]
        if !collectAllKubeEventsSetting.nil? && !collectAllKubeEventsSetting.empty?
          if collectAllKubeEventsSetting.casecmp("false") == 0
            @collectAllKubeEvents = false
            $log.warn("Normal kube events collection disabled for cluster")
          else
            @collectAllKubeEvents = true
            $log.warn("Normal kube events collection enabled for cluster")
          end
        end
      end
    end

    def shutdown
      if @run_interval
        @mutex.synchronize {
          @finished = true
          @condition.signal
        }
        @thread.join
      end
    end

    def enumerate
      begin
        eventList = nil
        currentTime = Time.now
        batchTime = currentTime.utc.iso8601
        eventQueryState = getEventQueryState
        newEventQueryState = []
        @eventsCount = 0

        # Initializing continuation token to nil
        continuationToken = nil
        $log.info("in_kube_events::enumerate : Getting events from Kube API @ #{Time.now.utc.iso8601}")
        if @collectAllKubeEvents
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?limit=#{@EVENTS_CHUNK_SIZE}")
        else
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?fieldSelector=type!=Normal&limit=#{@EVENTS_CHUNK_SIZE}")
        end

        $log.info("in_kube_events::enumerate : Done getting events from Kube API @ #{Time.now.utc.iso8601}")
        if (!eventList.nil? && !eventList.empty? && eventList.key?("items") && !eventList["items"].nil? && !eventList["items"].empty?)
          eventsCount = eventList["items"].length
          $log.info "in_kube_events::enumerate:Received number of events is eventList is #{eventsCount} @ #{Time.now.utc.iso8601}"
          if @ENABLE_PARSE_AND_EMIT
            newEventQueryState = parse_and_emit_records(eventList, eventQueryState, newEventQueryState, batchTime)
          end
        else
          $log.warn "in_kube_events::enumerate:Received empty eventList"
        end

        #If we receive a continuation token, make calls, process and flush data until we have processed all data
        while (!continuationToken.nil? && !continuationToken.empty?)
          continuationToken, eventList = KubernetesApiClient.getResourcesAndContinuationToken("events?fieldSelector=type!=Normal&limit=#{@EVENTS_CHUNK_SIZE}&continue=#{continuationToken}")
          if (!eventList.nil? && !eventList.empty? && eventList.key?("items") && !eventList["items"].nil? && !eventList["items"].empty?)
            eventsCount = eventList["items"].length
            $log.info "in_kube_events::enumerate:Received number of events is eventList is #{eventsCount} @ #{Time.now.utc.iso8601}"
            if @ENABLE_PARSE_AND_EMIT
              newEventQueryState = parse_and_emit_records(eventList, eventQueryState, newEventQueryState, batchTime)
            end
          else
            $log.warn "in_kube_events::enumerate:Received empty eventList"
          end
        end

        # Setting this to nil so that we dont hold memory until GC kicks in
        eventList = nil
        writeEventQueryState(newEventQueryState)

        # Flush AppInsights telemetry once all the processing is done, only if the number of events flushed is greater than 0
        if (@eventsCount > 0)
          ApplicationInsightsUtility.sendMetricTelemetry("EventCount", @eventsCount, {})
        end
      rescue => errorStr
        $log.warn "in_kube_events::enumerate:Failed in enumerate: #{errorStr}"
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end # end enumerate

    def parse_and_emit_records(events, eventQueryState, newEventQueryState, batchTime = Time.utc.iso8601)
      currentTime = Time.now
      emitTime = currentTime.to_f
      begin
        eventStream = MultiEventStream.new
        events["items"].each do |items|
          record = {}
          #<BUGBUG> - Not sure if ingestion has the below mapping for this custom type. Fix it as part of fixed type conversion
          record["CollectionTime"] = batchTime #This is the time that is mapped to become TimeGenerated
          eventId = items["metadata"]["uid"] + "/" + items["count"].to_s
          newEventQueryState.push(eventId)
          if !eventQueryState.empty? && eventQueryState.include?(eventId)
            next
          end

          nodeName = items["source"].key?("host") ? items["source"]["host"] : (OMS::Common.get_hostname)
          # For ARO v3 cluster, drop the master and infra node sourced events to ingest
          if KubernetesApiClient.isAROV3Cluster && !nodeName.nil? && !nodeName.empty? &&
             (nodeName.downcase.start_with?("infra-") || nodeName.downcase.start_with?("master-"))
            next
          end

          record["ObjectKind"] = items["involvedObject"]["kind"]
          record["Namespace"] = items["involvedObject"]["namespace"]
          record["Name"] = items["involvedObject"]["name"]
          record["Reason"] = items["reason"]
          record["Message"] = items["message"]
          record["KubeEventType"] = items["type"]
          record["TimeGenerated"] = items["metadata"]["creationTimestamp"]
          record["SourceComponent"] = items["source"]["component"]
          record["FirstSeen"] = items["firstTimestamp"]
          record["LastSeen"] = items["lastTimestamp"]
          record["Count"] = items["count"]
          record["Computer"] = nodeName
          record["ClusterName"] = KubernetesApiClient.getClusterName
          record["ClusterId"] = KubernetesApiClient.getClusterId
          wrapper = {
            "DataType" => "KUBE_EVENTS_BLOB",
            "IPName" => "ContainerInsights",
            "DataItems" => [record.each { |k, v| record[k] = v }],
          }
          eventStream.add(emitTime, wrapper) if wrapper
          @eventsCount += 1
        end
        if @EVENTS_EMIT_STREAM
          router.emit_stream(@tag, eventStream) if eventStream
        end
      rescue => errorStr
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      return newEventQueryState
    end

    def run_periodic
      @mutex.lock
      done = @finished
      @nextTimeToRun = Time.now
      @waitTimeout = @run_interval
      until done
        @nextTimeToRun = @nextTimeToRun + @run_interval
        @now = Time.now
        if @nextTimeToRun <= @now
          @waitTimeout = 1
          @nextTimeToRun = @now
        else
          @waitTimeout = @nextTimeToRun - @now
        end
        @condition.wait(@mutex, @waitTimeout)
        done = @finished
        @mutex.unlock
        if !done
          begin
            $log.info("in_kube_events::run_periodic.enumerate.start @ #{Time.now.utc.iso8601}")
            enumerate
            $log.info("in_kube_events::run_periodic.enumerate.end @ #{Time.now.utc.iso8601}")
          rescue => errorStr
            $log.warn "in_kube_events::run_periodic: enumerate Failed to retrieve kube events: #{errorStr}"
            ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
          end
        end
        @mutex.lock
      end
      @mutex.unlock
    end

    def getEventQueryState
      eventQueryState = []
      begin
        if File.file?(@@KubeEventsStateFile)
          # Do not read the entire file in one shot as it spikes memory (50+MB) for ~5k events
          File.foreach(@@KubeEventsStateFile) do |line|
            eventQueryState.push(line.chomp) #puts will append newline which needs to be removed
          end
        end
      rescue => errorStr
        $log.warn $log.warn line.dump, error: errorStr.to_s
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
      return eventQueryState
    end

    def writeEventQueryState(eventQueryState)
      begin
        if (!eventQueryState.nil? && !eventQueryState.empty?)
          # No need to close file handle (f) due to block scope
          File.open(@@KubeEventsStateFile, "w") do |f|
            f.puts(eventQueryState)
          end
        end
      rescue => errorStr
        $log.warn $log.warn line.dump, error: errorStr.to_s
        $log.debug_backtrace(errorStr.backtrace)
        ApplicationInsightsUtility.sendExceptionTelemetry(errorStr)
      end
    end
  end # Kube_Event_Input
end # module
