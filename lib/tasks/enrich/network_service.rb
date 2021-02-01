module Intrigue
module Task
module Enrich
class NetworkService < Intrigue::Task::BaseTask

  def self.metadata
    {
      :name => "enrich/network_service",
      :pretty_name => "Enrich Network Service",
      :authors => ["jcran"],
      :description => "Fills in details for a Network Service",
      :references => [],
      :type => "enrichment",
      :passive => false,
      :allowed_types => ["NetworkService"],
      :example_entities => [
        { "type" => "NetworkService", "details" => { "name" => "1.1.1.1:1111/tcp" } }
      ],
      :allowed_options => [],
      :created_types => []
    }
  end

  ## Default method, subclasses must override this
  def run
    _log "Enriching... Network Service: #{_get_entity_name}"

    ###
    ### First, normalize the nane - split out the various attributes
    ###
    entity_name = _get_entity_name

    # grab the ip, handling ipv6 gracefully
    if entity_name =~ /:/ 
      ip_address = entity_name.split(":")[0..-2].join(":")
    else 
      ip_address = entity_name.split(":").first
    end

    port = entity_name.split(":").last.split("/").first.to_i
    proto = entity_name.split(":").last.split("/").first.upcase
    net_name = _get_entity_detail("net_name")

    _set_entity_detail("ip_address", ip_address)
    _set_entity_detail("port", port)
    _set_entity_detail("proto", proto)

    # Use Ident to fingerprint
    _log "Grabbing banner and fingerprinting!"
    ident_response = fingerprint_service(ip_address, port, proto) 
    
    fingerprint = ident_response["fingerprint"]

    # set entity details 
    _set_entity_detail "fingerprint", fingerprint

    # Translate ident fingerprint (tags) into known issues
    create_issues_from_fingerprint_tags(fingerprint, @entity)
    
    # Create issues for any vulns that are version-only inference
    get_issue_by_cve_identifier(fingerprint, @entity)

    # Okay, now kick off vulnerability checks (if project allows)
    if @project.vulnerability_checks_enabled
      vuln_checks = run_vuln_checks_from_fingerprint(fingerprint, @entity)
      _set_entity_detail("vuln_checks", vuln_checks)
    end

    ###
    ### Handle SNMP as a special treat
    ###
    enrich_snmp if port == 161 && proto.upcase == "UDP"

    ###
    ### Hide Some services based on their attributes
    ###

    hide_value = false
    hide_reason = "default"

    # consider these noise
    noise_networks = [
      "CLOUDFLARENET - CLOUDFLARE, INC., US", 
      "GOOGLE, US", 
      "CLOUDFLARENET, US", 
      "GOOGLE-PRIVATE-CLOUD, US", 
      "INCAPSULA, US", 
      "INCAPSULA - INCAPSULA INC, US"
    ]

    # drop them if we don't have a fingerprint
    #
    # TODO ... this might need to be checked for a generic reset now
    #
    if noise_networks.include?(net_name) &&
         (_get_entity_detail("fingerprint") || []).empty?
      hide_value = true
      hide_reason = "noise_network"
    end

    known_ports = [
      { port: 2082, net_name: "CLOUDFLARENET, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::" },  
      { port: 2083, net_name: "CLOUDFLARENET, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },  
      { port: 2086, net_name: "CLOUDFLARENET, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },
      { port: 2087, net_name: "CLOUDFLARENET, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },
      { port: 2095, net_name: "CLOUDFLARENET, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  }, 
      { port: 2082, net_name: "GOOGLE, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::" },  
      { port: 2083, net_name: "GOOGLE, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },  
      { port: 2086, net_name: "GOOGLE, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },
      { port: 2087, net_name: "GOOGLE, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  },
      { port: 2095, net_name: "GOOGLE, US", cpe: "cpe:2.3::generic:connection_reset_(attempted_http_connection)::"  }, 
      { port: 25, net_name: "GOOGLE, US" }
    ]
    if known_ports.select{ |x| x[:port] == port && x[:net_name] == net_name }
      hide_reason = "Matched known hidden service"
      hide_value = true 
    end

    # Okay now hide based on our value 
    _log "Setting Hidden to: #{hide_value}, for reason: #{hide_reason}"
    @entity.hidden = hide_value 
    @entity.save_changes
  
  end

  def enrich_snmp
    _log "Enriching... SNMP service: #{_get_entity_name}"

    port = _get_entity_detail("port").to_i || 161
    ip_address = _get_entity_detail "ip_address"

    # Create a tempfile to store results
    temp_file = "#{Dir::tmpdir}/nmap_snmp_info_#{rand(100000000)}.xml"

    nmap_string = "nmap #{ip_address} -sU -p #{port} --script=snmp-info -oX #{temp_file}"
    nmap_string = "sudo #{nmap_string}" unless Process.uid == 0

    _log "Running... #{nmap_string}"
    nmap_output = _unsafe_system nmap_string

    # parse the file and get output, setting it in details
    doc = File.open(temp_file) { |f| Nokogiri::XML(f) }

    service_doc = doc.xpath("//service")
    begin
      if service_doc && service_doc.attr("product")
        snmp_product = service_doc.attr("product").text
      end
    rescue NoMethodError => e
      _log_error "Unable to find attribute: product"
    end

    begin
      script_doc = doc.xpath("//script")
      if script_doc && script_doc.attr("output")
        script_output = script_doc.attr("output").text
      end
    rescue NoMethodError => e
      _log_error "Unable to find attribute: output"
    end


    _log "Got SNMP details:#{script_output}"

    _set_entity_detail("product", snmp_product)
    _set_entity_detail("script_output", script_output)

    # cleanup
    begin
      File.delete(temp_file)
    rescue Errno::EPERM
      _log_error "Unable to delete file"
    end
  end

end
end
end
end