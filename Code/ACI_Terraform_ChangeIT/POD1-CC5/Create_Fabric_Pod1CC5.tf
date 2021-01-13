# read csv file
# changes to csv:
#   removed whitespaces from attribute names
locals {
  file_csv = file("${path.module}/POD1-FABRICACCESS.csv")
  input_csv = csvdecode(local.file_csv)
  infra_values = [
    for row in local.input_csv: 
      {
      "NODEID_FROM"  = row.NODEID_FROM
      "NODEID_TO"     = row.NODEID_TO
      "SwitchName"  = row.SwitchName
      "Port"     = row.Port
      "Description"    = row.Description
      "PolicyGroup"    = row.PolicyGroup
      "LinkLevel"    = row.LinkLevel
      "LLDP"    = row.LLDP
      "MCP"    = row.MCP
      "LACP"    = row.LACP
      "CDP"    = row.CDP
      "AAEP"    = row.AAEP
      "PGType"    = row.PGType
      "PD"    = row.PD
      }
  ]
  distinct_aaeps = distinct([for row in local.infra_values: [row.AAEP, row.PD]])
  distinct_switch_names = distinct([for row in local.infra_values: row.SwitchName])
  distinct_switch_names_w_ipr = [
      for switch in local.distinct_switch_names:
      {
        "SPR" = switch
        "IPR" = [
          for row in local.infra_values:
          row.SwitchName
          if row.SwitchName == switch
        ]
      }
  ]
  distinct_pg = distinct([
      for row in local.infra_values:
      {
        "PolicyGroup"    = row.PolicyGroup
        "LinkLevel"    = row.LinkLevel
        "LLDP"    = row.LLDP
        "MCP"    = row.MCP
        "LACP"    = row.LACP
        "CDP"    = row.CDP
        "AAEP"    = row.AAEP
        "PGType"    = row.PGType
        "PD"    = row.PD
      }
  ])
  distinct_swprof = distinct([
      for row in local.infra_values:
      {
        "SwitchName"    = row.SwitchName
        "NODEID_FROM"    = row.NODEID_FROM
        "NODEID_TO"    = row.NODEID_TO
      }
  ])
}

#configure provider with your cisco aci credentials.
provider "aci" {
  # cisco-aci user name
  username = "admin"
  # cisco-aci password
  password = "cwacilab"
  # cisco-aci url
  url      = "https://172.20.187.139"
  insecure = true
}

#interface profile
#Fabric -> Access Policies -> Interfaces -> Leaf Interfaces -> Profiles
resource "aci_leaf_interface_profile" "profile_list" {
  for_each = {for row in local.distinct_switch_names: row => row }
  name        = format("%s%s",each.value ,"_INTPROF")
}

#create aaeps
resource "aci_attachable_access_entity_profile" "aaep_list" {
  for_each  = {for aaep in local.distinct_aaeps : format("%s%s",aaep[0],aaep[1]) => aaep}
  name  = each.value[0]
  relation_infra_rs_dom_p = [format("uni/phys-%s", each.value[1])]
}

### if PGType == Access
resource "aci_leaf_access_port_policy_group" "appg_list" {
  for_each = {for row in local.distinct_pg: row.PolicyGroup => row if row.PGType == "Access"}
  #define right prefix
  name        = each.value.PolicyGroup
  #binding to policies - discuss naming
  relation_infra_rs_lldp_if_pol = "uni/infra/lldpIfP-${each.value.LLDP}"
  relation_infra_rs_cdp_if_pol = "uni/infra/cdpIfP-${each.value.CDP}"
  relation_infra_rs_mcp_if_pol = "uni/infra/mcpIfP-${each.value.MCP}"
  #linklevel
  relation_infra_rs_h_if_pol = "uni/infra/hintfpol-${each.value.LinkLevel}"
  
  #binding to aaep
  relation_infra_rs_att_ent_p = aci_attachable_access_entity_profile.aaep_list[format("%s%s",each.value.AAEP,each.value.PD)].id
} 

###if PGType == PC 
resource "aci_leaf_access_bundle_policy_group" "abpg_list_pc" {
  for_each = {for row in local.infra_values:row.distinct_pg => row if row.PGType == "PC"}
  #define right prefix
  name        = each.value.PolicyGroup
   #binding to policies - discuss naming
  relation_infra_rs_lldp_if_pol = "uni/infra/lldpIfP-${each.value.LLDP}"
  relation_infra_rs_cdp_if_pol = "uni/infra/cdpIfP-${each.value.CDP}"
  relation_infra_rs_mcp_if_pol = "uni/infra/mcpIfP-${each.value.MCP}"
  #linklevel
  relation_infra_rs_h_if_pol = "uni/infra/hintfpol-${each.value.LinkLevel}"
  #pc
  relation_infra_rs_lacp_pol = "uni/infra/lacplagp-${each.value.LACP}"
  #binding to aaep
  relation_infra_rs_att_ent_p = aci_attachable_access_entity_profile.aaep_list[each.value.AAEP].id
} 

###if PGType == VPC
resource "aci_leaf_access_bundle_policy_group" "abpg_list_vpc" {
  for_each = {for row in local.distinct_pg: format("%s%s%s",row.PolicyGroup, row.PD, row.AAEP) => row if row.PGType == "VPC"}
  #define right prefix
  name        = each.value.PolicyGroup
  lag_t       = "node"
   #binding to policies - discuss naming
  relation_infra_rs_lldp_if_pol = "uni/infra/lldpIfP-${each.value.LLDP}"
  relation_infra_rs_cdp_if_pol = "uni/infra/cdpIfP-${each.value.CDP}"
  relation_infra_rs_mcp_if_pol = "uni/infra/mcpIfP-${each.value.MCP}"
  #linklevel
  relation_infra_rs_h_if_pol = "uni/infra/hintfpol-${each.value.LinkLevel}"
  #pc
  relation_infra_rs_lacp_pol = "uni/infra/lacplagp-${each.value.LACP}"
  #binding to aaep
  relation_infra_rs_att_ent_p = aci_attachable_access_entity_profile.aaep_list[format("%s%s",each.value.AAEP,each.value.PD)].id
} 

#add port selector to leaf interface profile
#need interface policy group
resource "aci_rest" "leaf_port_selector_list" {
  for_each  = {for port in local.infra_values : format("%s%s%s%s",port.Port,port.PD,port.NODEID_FROM, port.AAEP) => port}
  path       = format("api/node/mo/uni/infra/accportprof-%s/hports-%s-typ-range.json", format("%s%s",each.value.SwitchName ,"_INTPROF"), format("%s%s","ETH_1_",each.value.Port))
  payload = <<EOF
  {
   "infraHPortS":{
      "attributes":{
         "dn":"uni/infra/accportprof-${format("%s%s",each.value.SwitchName ,"_INTPROF")}/hports-${format("%s%s","ETH_1_",each.value.Port)}-typ-range",
         "name":"${format("%s%s","ETH_1_",each.value.Port)}",
         "rn":"hports-${format("%s%s","ETH_1_",each.value.Port)}-typ-range",
         "status":"created,modified"
      },
      "children":[
         {
            "infraPortBlk":{
               "attributes":{
                  "dn":"uni/infra/accportprof-${format("%s%s",each.value.SwitchName ,"_INTPROF")}/hports-${format("%s%s","ETH_1_",each.value.Port)}-typ-range/portblk-${format("%s%s","BLK_",each.value.Port)}",
                  "fromPort":"${each.value.Port}",
                  "toPort":"${each.value.Port}",
                  "descr":"${each.value.Description}",
                  "name":"${format("%s%s","BLK_",each.value.Port)}",
                  "rn":"portblk-${format("%s%s","BLK_",each.value.Port)}",
                  "status":"created,modified"
               },
               "children":[
                  
               ]
            }
         },
         {
            "infraRsAccBaseGrp":{
               "attributes":{
                  "tDn":"uni/infra/funcprof/accbundle-${each.value.PolicyGroup}",
                  "status":"created,modified"
               },
               "children":[
                  
               ]
            }
         }
      ]
   }
}
EOF
}

#leaf profile
#Fabric -> Access Policies -> Switches -> Leaf Switches -> Profiles
resource "aci_leaf_profile" "leaf_profile_list" {
  for_each = {for row in local.distinct_swprof: row.SwitchName => row }
  name        = format("%s%s",each.value.SwitchName, "_SWPROF")
  leaf_selector {
    name                    = format("%s%s","SSL_",each.value.SwitchName)
    switch_association_type = "range"
    node_block {
      #has to be dynamically assigned - values not available yet
      name  = format("%s%s_%s","BLK_",each.value.NODEID_FROM, each.value.NODEID_TO)
      from_ = each.value.NODEID_FROM
      to_   = each.value.NODEID_TO
    }
  }
  #can only bind list of intprofiles
  relation_infra_rs_acc_port_p = [aci_leaf_interface_profile.profile_list[each.value.SwitchName].id]
}


