# read csv file
# changes to csv:
#   removed whitespaces from attribute names
locals {
  file_csv = file("${path.module}/POD2-FABRICACCESS.csv")
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
      }
  ]
  distinct_switch_names = distinct([for row in local.infra_values: row.SwitchName])
  distinct_switch_names_w_ipr = [
      for switch in local.distinct_switch_names:
      {
        "SPR" = switch
        "IPR" = [
          for row in local.infra_values:
          row.Name
          if row.SwitchName == switch
        ]
      }
  ]
  spr_names = distinct([for row in local.infra_values: format("%s%s","SPR_",row.SwitchName)])
}

output "test" {
  value = local.distinct_switch_names_w_ipr
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
  name        = format("%s%s",row ,"_INTPROF")
}


### if PGType == Access
resource "aci_leaf_access_port_policy_group" "appg_list" {
  for_each = {for row in local.infra_values: row.PolicyGroup => row if row.PGType == "Access"}
  #define right prefix
  name        = each.value.PolicyGroup
  #binding to policies - discuss naming
  
  relation_infra_rs_lldp_if_pol = each.value.LLDP
  relation_infra_rs_cdp_if_pol = each.value.CDP
  relation_infra_rs_mcp_if_pol = each.value.MCP
  #linklevel
  relation_infra_rs_h_if_pol = each.value.LinkLevel
  
  #binding to aaep
  relation_infra_rs_att_ent_p = aci_attachable_access_entity_profile.aaep_list[each.value.AAEP].id
} 

###if PGType == PC or VPC
resource "aci_leaf_access_bundle_policy_group" "abpg_list" {
  for_each = {for row in local.infra_values:row.PolicyGroup => row if row.PGType != "Access"}
  #define right prefix
  name        = each.value.PolicyGroup
  #binding to policies - discuss naming
  relation_infra_rs_lldp_if_pol = each.value.LLDP
  relation_infra_rs_cdp_if_pol = each.value.CDP
  relation_infra_rs_mcp_if_pol = each.value.MCP
  #linklevel
  relation_infra_rs_h_if_pol = each.value.LinkLevel
  #pc
  relation_infra_rs_lacp_pol = each.value.LACP
  #binding to aaep
  relation_infra_rs_att_ent_p = aci_attachable_access_entity_profile.aaep_list[each.value.AAEP].id
} 

#add port selector to leaf profile
#need interface policy group
resource "aci_rest" "leaf_port_selector_list" {
  for_each  = {for port in local.infra_values : port.Port => port}
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
resource "aci_leaf_profile" "example" {
  for_each = {for row in local.infra_values: row.SwitchName => row }
  name        = format("%s%s",each.value.SwitchName, "_SWPROF")
  leaf_selector {
    name                    = format("%s%s","SSL_",each.value.SwitchName)
    node_block {
      #has to be dynamically assigned - values not available yet
      name  = format("%s%s_%s","BLK_",each.value.NODEID_FROM, each.value.NODEID_TO)
      from_ = each.value.NODEID_FROM
      to_   = each.value.NODEID_TO
    }
  }
  #can only bind list of intprofiles
  relation_infra_rs_acc_port_p = [aci_leaf_interface_profile.profile_list[format("%s%s",each.value.SwitchName, "_INTPROF")].id]
}

#add interface policies
#link level policy
resource "aci_fabric_if_pol" "100M_autoneg" {
  name        = "100M_autoneg"
  speed       = "100M"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "100M_forced" {
  name        = "100M_forced"
  speed       = "100M"
  auto_neg    = "off"
}

resource "aci_fabric_if_pol" "1G_autoneg" {
  name        = "1G_autoneg"
  speed       = "1G"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "1G_forced" {
  name        = "1G_forced"
  speed       = "1G"
  auto_neg    = "off"
}

#right syntax
resource "aci_fabric_if_pol" "10GIGAUTO" {
  name        = "10GIGAUTO"
  speed       = "10G"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "10GIG" {
  name        = "10GIG"
  speed       = "10G"
  auto_neg    = "off"
}

#right syntax
resource "aci_fabric_if_pol" "25GIGAUTO" {
  name        = "25GIGAUTO"
  speed       = "25G"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "25GIG" {
  name        = "25GIG"
  speed       = "25G"
  auto_neg    = "off"
}

#right syntax
resource "aci_fabric_if_pol" "40GIGAUTO" {
  name        = "40GIGAUTO"
  speed       = "40G"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "40GIG" {
  name        = "40GIG"
  speed       = "40G"
  auto_neg    = "off"
}

#right syntax
resource "aci_fabric_if_pol" "100GIGAUTO" {
  name        = "100GIGAUTO"
  speed       = "100G"
  auto_neg    = "on"
}

resource "aci_fabric_if_pol" "100GIG" {
  name        = "100GIG"
  speed       = "100G"
  auto_neg    = "off"
}

#cdp
resource "aci_cdp_interface_policy" "CDP_ENABLED" {
  name        = "CDP_ENABLED"
  admin_st    = "enabled"
}

resource "aci_cdp_interface_policy" "CDP_DISABLED" {
  name        = "CDP_DISABLED"
  admin_st    = "disabled"
}

#lldp
resource "aci_lldp_interface_policy" "LLDP_ENABLED" {
  name        = "LLDP_ENABLED"
  admin_rx_st = "enabled"
  admin_tx_st = "enabled"
}

resource "aci_lldp_interface_policy" "LLDP_DISABLED" {
  name        = "LLDP_DISABLED"
  admin_rx_st = "disabled"
  admin_tx_st = "disabled"
}

#mcp
resource "aci_miscabling_protocol_interface_policy" "MCP_ENABLED" {
  name        = "MCP_ENABLED"
  admin_st    = "enabled"
}

resource "aci_miscabling_protocol_interface_policy" "MCP_DISABLED" {
  name        = "MCP_DISABLED"
  admin_st    = "disabled"
}

#lacp
resource "aci_lacp_policy" "lacp_enabled" {
  name        = "LACP_enabled"
  ctrl        = ["susp-individual", "fast-sel-hot-stdby", "graceful-conv"]  #default
  mode        = "active"
}


