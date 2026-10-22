This doc is a brief sketch for self developing dpu processor design (Hunter Vision Unit, mark 1), project code is hvu1, the ryan's display process unit mark 1.
# Overview
## Feature brief
- process raw image data and generate as video stream data protocol for display port IP.
- support video mode and command mode, while in video mode, will read from a command descriptor ring and processing the image data according to the descripotr commands, and generates video stream.
- memory fetch, feature for how to fetch the data from memory, [[../../../linlon_d6/star1_linlon_d6/doc/raw/design_notes/modules/linlon_d6_memory_subsystem|linlon_d6_memory_subsystem]]
- 4 separated and standalone display links, each link can support dual_link with extra high bits of pixel data.
- each display link shall have one composition unit so that can blend mixed images into a single display scene, so hvu has 4 composition unit in total.
- each composition unit connected with 4 layer processor, which means each cu has maximum 4 layer composite to display output directly or to another cu and composite with others.
- if the corresponding display output unit is enabled, then the cu output will be directly displayed, or else will be bypassed to another cu.

### composition unit
The composition unit supports:
- blending by different input layer, with configurable position and blending transparancy(alpha).
	- register config has a start position of an input layer, and hardware will calculate the detailed position according to the input layer size and the start point.
	- the blender has a configurable alpha that used if the input pixels' alpha is disabled
- the cu supports maximun 3 blenders, 2 for input layers and 1 from last level cu.
- the 2 input layer can configured within each two of the 8 layers
### layer unit
- resize, support linear or bicubic interpolation
- rotate 90, 180, 270
- hflip, vflip.
- CSC, the color space change, supports typical color format changes:
	- rgba/argb <-> yuv444
	- yuv444 <-> yuv422
	- yuv422 <-> yuv420
## Overall diagram
![[../../../../Misc/Attachment/Pasted image 20260901210105.png]]

## Brief structure
### top perspective
the top module name is `hvu1_core`, which instantiated the first level units of:
- [[hvu1_layer_unit]]
- `hvu1_display_unit`
- `hvu1_composition_unit`





# Architecture


## hvu1_display_unit
*PS*: more details specification will be depicted in separate display_unit file.
The hvu1_display_unit (du) is only a container that contains 4 display output cores, named as hvu1_dou_core. Each dou core are standalone links to generate required video stream based on given configurations.
The display unit connected with each composition unit (cu) with the internal pixel data, valid/ready handshake signals, and so as the dou_en passed to cu to bypass the cu's pixel output to a next cu pipe or to du directly.
### interactions
- pixel_data/valid/ready, used to send cu data to du, one cu connected to the fixed du in hardware.
	- valid/data, cu -> du
	- ready, du -> cu
- du_en, du -> cu indicate the du is enabled
- cr_sel/wr/wd/rd/addr, apb -> du, the decoded register interface.
### components/instances
- hvu1_dou_core, core to behave and generate video stream according to color depth, ppc, dual link etc.
- register control, reg nets used to control the dou behavior.


## hvu1_composition_unit
The unit has 8 layer pixels input, and the zmux will first help select which 2 layer pixels will be passed to each cu. That means the cu's input layer can dynamically configured by the register controll.
### features
- mux the input layer0~7 pixel streams to different composition core.

### components/instances
- hvu1_zmux, muxing the input hardware layer index to virtual input layer of each composition_core.
- hvu1_composition_core, the core that will do pixel blending.
- register control, reg nets used to control the cu behavior.


## hvu1_layer_unit

### features

*resize process*
if resize is enabled, it will calculate the required pixel position and fetch pixel data from memory, then do interpolation to generate target pixel value.
if resize is not enabled, then the resize module will generate address walk line by line.

*rot/flip*
if this enabled, the module will calculate target pixel position according to the input position.

*axis pos to address convert*
The module supports input axis position to memory address convert.

*csc*
module that converting different formats into the same argb8888 format for internal process.

### interface
fetch request bundle to dma x 8.
rgb pixel stream to cu x 8.
register internal decoded access bundle from hvu1_sys_ctrl.

### components/instances
*hvu1_layer_control*:
the detailed behaviors for the layer process, like the resize, rotate etc.
data stream:
1. user config -> enable the layer controller.
2. do csc first, according to the input color format, need convert to internal used format (argb_8888)
3. calculate the rotate/flip positions.
4. resize stage
5. then do resize/rotate/flip operations.
	1. will first do rotate/flip combination, then resize.
	
#TBD block level operation for rot, so that can reduce hard resource
partition -> rot+flip -> resize

**detailed for yuv format in system memory**
- planar
- nv21
the alpha value of argb can be specified by register configure if the input format is yuv.
[[hvu1_layer_unit]]



*hvu1_layer_register*
register signals that pass to each controller for configurations.

### interfaces
- internal request to hvu1_mem_system, each controller have a standalone bundle to send request and receive responses.

## hvu1_sys_ctrl
operating for register access control.
- user to confirm the last step is always the enable field setting of each component.
## hvu1_mem_system
the memory system, has cache miss/hit, dma request features.






