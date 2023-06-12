using LegendDataManagement
using PropertyFunctions

config_filename = "/home/iwsatlas1/henkes/l200/p03/config.json"
config = LegendDataConfig(config_filename)
l200 = LegendData(config.setups.l200)

# l200 = LegendData(:l200)

filekey = FileKey("l200-p02-r006-cal-20221226T200846Z")
filekey = FileKey("l200-p02-r006-cal*")
periodData = DataPeriod(l200, "p03")


raw_filename = l200.tier[:raw, "l200-p02-r006-cal-20221226T200846Z"]

l200.metadata.hardware.detectors.germanium.diodes

chinfo = channel_info(l200, filekey)
geds = filterby(@pf $processable && $usability && $system == :geds)(chinfo)
geds.rawid