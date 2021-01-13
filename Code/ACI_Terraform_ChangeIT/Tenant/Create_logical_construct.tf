# read csv file
# changes to csv:
#   removed whitespaces from attribute names
locals {
  file_csv_logical = file("${path.module}/TENANT-VRF-BD-EPG_testnative.csv")
  input_csv_logical = csvdecode(local.file_csv_logical)
  infra_logical_values = [
    for row in local.input_csv_logical: 
      {
      "Tenant"  = row.Tenant
      "AP"      = row.AP
      "VRF"     = row.VRF
      "PD"      = row.Domain
      "VLP"     = row.VLAN_Pool
      "BD"      = row.BD_Name
      "BD_IP"  = row.BD_IP
      "EPG"     = row.EPG_Name
      "VLAN"    = row.VLAN_ID
      "NODEID_FROM"  = row.NODEID_FROM
      "NODEID_TO"     = row.NODEID_TO
      "Port"     = row.Port
      "PGType"     = row.PGType
      "Mode"     = row.Mode
      "PG"     = row.PolicyGroup
      }
  ]
  infra_logical_values_no_port = distinct([
    for row in local.infra_logical_values: 
      {
      "Tenant"  = row.Tenant
      "AP"      = row.AP
      "VRF"     = row.VRF
      "PD"      = row.PD
      "VLP"     = row.VLP
      "BD"      = row.BD
      "BD_IP"  = row.BD_IP
      "EPG"     = row.EPG
      "VLAN"    = row.VLAN
      }
  ])
  #get list of tenants
  tenants = distinct([for row in local.infra_logical_values_no_port: row.Tenant])  
  #get list of tenants without "_DEV" for further use with aaep, domain & vlan pool
  #list of vlan_pools
  vlan_pools = distinct([for row in local.infra_logical_values_no_port: row.VLP])
  #list of domains
  domains = distinct([for row in local.infra_logical_values_no_port: [row.PD, row.VLP]])
  #list of aaeps
  vrfs = distinct([for row in local.infra_logical_values_no_port: [row.Tenant, row.VRF]])
  aps = distinct([for row in local.infra_logical_values_no_port: [row.Tenant, row.AP]])
  subnets = [for bd in local.infra_logical_values_no_port: [bd.BD, bd.BD_IP] if bd.BD_IP != ""]
}

provider "aci" {
  # cisco-aci user name
  username = "admin"
  # cisco-aci password
  password = "cwacilab"
  # cisco-aci url
  url      = "https://172.20.187.139"
  insecure = true
}

#create the tenants
resource "aci_tenant" "tenant_list" {
  for_each  = {for tenant in local.tenants : tenant => tenant}
  name        = each.value
  description = "This tenant is created by terraform out of a csv file"
}

#create vlan pools
resource "aci_vlan_pool" "vlan_pool_list" {
  for_each  = {for vlan_pool in local.vlan_pools : vlan_pool => vlan_pool}
  name  = each.value
  alloc_mode = "dynamic"
}

#create vlans
resource "aci_ranges" "vlan_id_list" {
  for_each = {for vlan_id in local.infra_logical_values_no_port : vlan_id.VLAN => vlan_id}
  vlan_pool_dn = aci_vlan_pool.vlan_pool_list[each.value.VLP].id
  _from = format("%s%s", "vlan-", each.value.VLAN)
  to = format("%s%s", "vlan-", each.value.VLAN)
  alloc_mode = "static"
}

#create physical domains
resource "aci_physical_domain" "domain_list" {
  for_each  = {for domain in local.domains : domain[0] => domain}
  name  = each.value[0]
  relation_infra_rs_vlan_ns = aci_vlan_pool.vlan_pool_list[each.value[1]].id
}

#create vrfs
resource "aci_vrf" "vrf_list" {
  for_each = { for vrf in local.vrfs : vrf[1] => vrf }
  tenant_dn              = aci_tenant.tenant_list[each.value[0]].id
  name                   = each.value[1]
}

#create bds 
resource "aci_bridge_domain" "bd_list" {
  for_each  = {for bd in local.infra_logical_values_no_port : bd.BD => bd}
  tenant_dn                   = aci_tenant.tenant_list[each.value.Tenant].id
  name                        = each.value.BD
  arp_flood                   = each.value.BD_IP == "" ? "yes" : "no"
  unk_mac_ucast_act           = each.value.BD_IP == "" ? "flood" : "proxy"
  unk_mcast_act               = each.value.BD_IP == "" ? "flood" : "opt-flood" 
  multi_dst_pkt_act           = "bd-flood" #default
  #garp required to configure
  unicast_route               = each.value.BD_IP == "" ? "no" : "yes"
}

#create subnets for bds
resource "aci_subnet" "subnet_list" {
  for_each = { for ip in local.subnets : ip[1] => ip }
  parent_dn        = aci_bridge_domain.bd_list[each.value[0]].id
  ip               = each.value[1]
}

#bind bd to vrf
#method: POST
#url: http://172.20.187.139/api/node/mo/uni/tn-DC_DEV/BD-BD_VL955_DEV_TSM_BACKUP/rsctx.json
#payload{"fvRsCtx":{"attributes":{"tnFvCtxName":"DEV_TSM_BACKUP"},"children":[]}}
#response: {"totalCount":"0","imdata":[]}
resource "aci_rest" "bd_vrf_bindings" {
  for_each  = {for bd in local.infra_logical_values_no_port : bd.BD => bd}
  path       = format("api/node/mo/uni/tn-%s/BD-%s/rsctx.json", each.value.Tenant, each.value.BD)
  payload = format("{\"fvRsCtx\":{\"attributes\":{\"tnFvCtxName\":\"%s\"},\"children\":[]}}", each.value.VRF)
}

#create aps
resource "aci_application_profile" "ap_list" {
  #work over syntax
  for_each  = {for ap in local.aps : ap[1] => ap}
  tenant_dn                   = aci_tenant.tenant_list[each.value[0]].id
  name                        = each.value[1]
}

#create epgs
resource "aci_application_epg" "epg_list" {
  for_each  = {for epg in local.infra_logical_values_no_port : epg.EPG => epg}
  application_profile_dn      = aci_application_profile.ap_list[each.value.AP].id
  name                        = each.value.EPG
  relation_fv_rs_bd           = aci_bridge_domain.bd_list[each.value.BD].id
}

#associate domain with epg
resource "aci_epg_to_domain" "epg_domain_list" {
  for_each = {for epg in local.infra_logical_values_no_port : epg.EPG => epg }
  application_epg_dn = aci_application_epg.epg_list[each.value.EPG].id
  tdn = aci_physical_domain.domain_list[each.value.PD].id
}

#access
resource "aci_epg_to_static_path" "epg_port_bindings" {
  for_each = {for row in local.infra_logical_values: format("%s%s%s%s",row.EPG,row.Port, row.VLAN, row.NODEID_FROM) => row if row.PGType == "Access"}
  application_epg_dn  = aci_application_epg.epg_list[each.value.EPG].id
  tdn  = format("topology/pod-%s/paths-%s/pathep-[eth1/%s]",substr(each.value.NODEID_FROM, 0, 1), each.value.NODEID_FROM, each.value.Port)
  encap  = format("vlan-%s", each.value.VLAN)
  instr_imedcy = "immediate"
  mode  = each.value.Mode
}

#pc port epg binding rest call
#method: POST
#url: http://172.20.187.139/api/node/mo/uni/tn-ecb_test1/ap-ecb_test1_AP/epg-VL111_ecb_test1_EPG.json
#payload{"fvRsPathAtt":{"attributes":{"encap":"vlan-223","instrImedcy":"immediate","tDn":"topology/pod-1/paths-1001/pathep-[MeinTestEinsDrei]","status":"created"},"children":[]}}
#response: {"totalCount":"0","imdata":[]}
#need interface policy group
resource "aci_rest" "epg_port_bindings_pc" {
  for_each  = {for port in local.infra_logical_values : format("%s%s%s%s",port.EPG,port.Port, port.VLAN, port.NODEID_FROM) => port if port.PGType == "PC"}
  path       =  format("api/node/mo/uni/tn-%s/ap-%s/epg-%s.json", each.value.Tenant, each.value.AP ,each.value.EPG)
  payload = <<EOF
  {
   "fvRsPathAtt":{
      "attributes":{
         "encap":"${each.value.VLAN}",
         "instrImedcy":"immediate",
         "tDn":"topology/pod-${substr(each.value.NODEID_FROM, 0, 1)}/paths-${each.value.NODEID_FROM}/pathep-[${each.value.PG}]",
         "status":"created"
         "mode":"${each.value.Mode}"
      },
      "children":[
         
      ]
   }
}
EOF
}

#vpc port epg binding rest call
#method: POST
#url: http://172.20.187.139/api/node/mo/uni/tn-ecb_test1/ap-ecb_test1_AP/epg-VL111_ecb_test1_EPG.json
#payload{"fvRsPathAtt":{"attributes":{"encap":"vlan-222","instrImedcy":"immediate","tDn":"topology/pod-1/protpaths-1001-1002/pathep-[Kopplung-L2-2960-VPC-IPG]","status":"created"},"children":[]}}
#response: {"totalCount":"0","imdata":[]}
#####
#         "mode":"${each.value.Mode}"
resource "aci_rest" "epg_port_bindings_vpc" {
  for_each  = {for port in local.infra_logical_values : format("%s%s%s%s",port.EPG,port.Port, port.VLAN, port.NODEID_FROM) => port if port.PGType == "VPC"}
  path       = format("api/node/mo/uni/tn-%s/ap-%s/epg-%s.json", each.value.Tenant, each.value.AP ,each.value.EPG)
  payload = <<EOF
  {
   "fvRsPathAtt":{
      "attributes":{
         "encap":"vlan-${each.value.VLAN}",
         "instrImedcy":"immediate",
         "tDn":"topology/pod-${substr(each.value.NODEID_FROM, 0, 1)}/protpaths-${each.value.NODEID_FROM}-${each.value.NODEID_TO}/pathep-[${each.value.PG}]",
         "status":"created",
         "mode":"${each.value.Mode}"
      },
      "children":[
         
      ]
   }
}
EOF
}

################  CONTRACT #################
/*method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-DC_DEV/brc-VZAny.json
payload{"vzBrCP":{"attributes":{"dn":"uni/tn-DC_DEV/brc-VZAny","name":"VZAny","rn":"brc-VZAny","status":"created"},"children":[{"vzSubj":{"attributes":{"dn":"uni/tn-DC_DEV/brc-VZAny/subj-VZAny_Subject","name":"VZAny_Subject","rn":"subj-VZAny_Subject","status":"created"},"children":[{"vzRsSubjFiltAtt":{"attributes":{"status":"created,modified","tnVzFilterName":"default","directives":"none"},"children":[]}}]}}]}}
response: {"totalCount":"0","imdata":[]}*/
resource "aci_rest" "vzany_contract" {
  for_each  = {for tenant in local.tenants : tenant => tenant}
  path       = "api/node/mo/uni/tn-${each.value}/brc-VZAny.json"
  payload = <<EOF
  {
   "vzBrCP":{
      "attributes":{
         "dn":"uni/tn-${each.value}/brc-VZAny",
         "name":"VZAny",
         "rn":"brc-VZAny",
         "status":"created"
      },
      "children":[
         {
            "vzSubj":{
               "attributes":{
                  "dn":"uni/tn-${each.value}/brc-VZAny/subj-VZAny_Subject",
                  "name":"VZAny_Subject",
                  "rn":"subj-VZAny_Subject",
                  "status":"created"
               },
               "children":[
                  {
                     "vzRsSubjFiltAtt":{
                        "attributes":{
                           "status":"created,modified",
                           "tnVzFilterName":"default",
                           "directives":"none"
                        },
                        "children":[
                           
                        ]
                     }
                  }
               ]
            }
         }
      ]
   }
}
EOF
}

/*method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-D_A/ctx-D_A2_VRF/any.json
payload{"vzRsAnyToCons":{"attributes":{"tnVzBrCPName":"VZAny","status":"created"},"children":[]}}
response: {"totalCount":"0","imdata":[]}*/
resource "aci_rest" "vzany_contract_vrf_cons" {
  for_each = { for vrf in local.vrfs : vrf[1] => vrf }
  path       = "api/node/mo/uni/tn-${each.value[0]}/ctx-${each.value[1]}/any.json"
  payload = <<EOF
  {"vzRsAnyToCons":{"attributes":{"tnVzBrCPName":"VZAny","status":"created"},"children":[]}}
EOF
}

/*method: POST
url: http://172.20.187.139/api/node/mo/uni/tn-D_A/ctx-D_A2_VRF/any.json
payload{"vzRsAnyToProv":{"attributes":{"tnVzBrCPName":"VZAny","status":"created"},"children":[]}}
response: {"totalCount":"0","imdata":[]} */
resource "aci_rest" "vzany_contract_vrf_prov" {
  for_each = { for vrf in local.vrfs : vrf[1] => vrf }
  path       = "api/node/mo/uni/tn-${each.value[0]}/ctx-${each.value[1]}/any.json"
  payload = <<EOF
  {"vzRsAnyToProv":{"attributes":{"tnVzBrCPName":"VZAny","status":"created"},"children":[]}}
EOF
}


/*
resource "aci_any" "fooany" {
  for_each = { for vrf in local.vrfs : vrf[1] => vrf }
  vrf_dn       = "${aci_vrf.vrf_list[each.value[1]].id}"
  relation_vz_rs_any_to_cons = ["uni/tn-${each.value[0]}/brc-VZAny"]
  relation_vz_rs_any_to_prov = ["uni/tn-${each.value[0]}/brc-VZAny"]
}*/