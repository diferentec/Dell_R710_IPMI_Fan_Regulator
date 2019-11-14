#!/bin/bash



#Copyright (c) 2019 Diferentec
#Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


# -------------------------------------------------------------------------------
# Script para controlar la velocidad de los ventiladores de un Dell R710 según la 
#	temperatura ambiente registrada y con un máximo como medida de seguridad para
#	saltar a modo automático
#
# Ha de ejecutarse como root para poder escribir en los ficheros seleccionados se
#	pueden modificar las rutas para ejecutarlo como un usuario no privilegiado 
#	pero ha de tenerse en cuenta que se escriben las credenciales en claro y hay
#	que bloquear la lectura desde usuarios no privilegiados
#
# Necesita:
# ipmitool – apt-get install ipmitool
# slacktee.sh – https://github.com/course-hero/slacktee  --> deshabilitado
# -------------------------------------------------------------------------------

# -------------------------------------------------------------------------------
# TODO:
#	- Controlar la inicialización a manual en la primera ejecución.
#	- Leer el valor de control automático y no dejar atrás el fichero.
#	- Cambiar el modo de autentificación para no poner las credenciales en claro.
#	- Pasar a /bin/sh o python y cambiar systemd-cat para ampliar compatibilidad.
#	- Configurar slacktee.sh y verificar la capacidad de notificación.
# -------------------------------------------------------------------------------



#  ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01 ## Auto
#  ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x00 ## Manual

# -------------------------------------------------------------------------------
# A modificar para poner en marcha
# -------------------------------------------------------------------------------
# Configuración IPMI:
# IP por defecto: 192.168.0.120
Host_IPMI=XXX.XXX.XXX.XXX
# Usuario por defecto: root
User_IPMI=XXXXXXXX
# Clave por defecto: calvin
Passw_IPMI=XXXXXXX
EncKey_IPMI=0000000000000000000000000000000000000000
# Configuración del script:
Fich_auto=/root/auto_vent	# Fichero para saber si se ha puesto en auto
Fich_temp=/root/.temp		# Fichero para uso temporal
N_Vent=5					# Número de ventiladores del sistema
Vel_minima=1080				# Velocidad media registrada para 0x00
D_rpm=120					# Delta de RPM observada entre pasos del hexadecimal.
# -------------------------------------------------------------------------------
# A modificar para poner a punto
# -------------------------------------------------------------------------------
# Temperaturas:
# 	Configura la temperatura ambiente máxima a la que dejará de tener el control
#		el script y pasará a control automático.
Max_A_Temp=40
#	Temperatura ambiente deseada de operación siempre ha de ser algo más elevada
#		que la temperatura ambiente de la sala, si no, el script nunca bajará la
#		velocidad de los ventiladores.
A_Temp_Deseada=25
#	Grados de margen antes de elevar la velocidad de los ventiladores
#		(Histéresis)
Hist=5
# Velocidad de cambio:
#	Cantidad de pasos a modificar la velocidad cada vez que se den las
#		condiciones para el cambio
D_pasos=3
# Tope superior
#	Velocidad máxima para la que se quiere usar el script o el valor de 0xff
Vel_maxima=5000
#	Valor máximo de pasos según la Vel_maxima
Max_pasos=$(($Vel_maxima / $D_rpm))
# -------------------------------------------------------------------------------


# Función leer valores de ventilador y devolver velocidad media
# Salidas posibles
#	- RPM
#	- E_numero (error en número de ventiladores o líneas).
#	- E_fallo (hay un ventilador fallando).
function velocidad_ventiladores {
	bien=0
#	echo $N_Vent
	if [ -f $Fich_temp ];
	then
		rm $Fich_temp
	fi
	ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI sdr type fan |grep "FAN " >> $Fich_temp
#	# Sólo funciona hasta 99 ventiladores
	if [ $((`wc -l $Fich_temp |cut -c -2`)) -ne $(($N_Vent)) ];
	then
		salida_funcion="E_numero"
	else
		i=0
		while read -r linea; do
#			echo "Linea - $line"
			vent_ok[$i]=`echo $linea |cut -s -d '|' -f 3 |xargs`
			vent_rpm[$i]=`echo $linea |cut -s -d '|' -f 5 |cut -d ' ' -f 2 |xargs`
#			echo "status: ${vent_ok[$i]}  RPM: ${vent_rpm[$i]}"
			((i++))
		done < $Fich_temp
		rpm_suma=0
		for i in "${vent_ok[@]}";
		do
#			echo "status: ${vent_ok[$i]}  RPM: ${vent_rpm[$i]}"
			if [ "${vent_ok[$i]}" == "ok" ];
			then
				rpm_suma=$(($rpm_suma + ${vent_rpm[$i]}))
			else
				salida_funcion="E_fallo"
			fi
		done
#		echo $rpm_suma
		rpm_media=$(($rpm_suma / ${#vent_ok[@]}))
		if [ "$salida_funcion" != "E_fallo" ];
		then
			salida_funcion=$rpm_media
		fi
	fi
	# Hacemos limpieza
	unset vent_ok
	unset vent_rpm
	if [ -f $Fich_temp ];
	then
		rm $Fich_temp
	fi
	
	#devolvemos un valor
	echo $salida_funcion
}


# -------------------------------------------------------------------------------
# MAIN 
# -------------------------------------------------------------------------------

# Adquirimos el dato de la temperatura ambiente actual.
A_Temp=$(ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI sdr type temperature |grep Ambient |grep degrees |grep -Po '\d{2}' | tail -1)

# Calculamos la temperatura a la que aumentaríamos la velocidad de los ventiladores.
A_Temp_Cambio=$(($A_Temp_Deseada + $Hist))

#A_Temp=36

if [[ $A_Temp > $Max_A_Temp ]];
then
    printf "Warning: Máximo sobrepasado! ($A_Temp C)" | systemd-cat -t Script_Vent_R710
	# TODO
	# echo "Warning: Máximo sobrepasado! Activando control automático! ($A_Temp C)" | /usr/bin/slacktee.sh -t "Script_Vent_R710 [$(hostname)]"
	# TODO
	# Cambiar fichero por comprobación directa del valor.
	if [ -f $Fich_auto ];
	then
		printf "Ya está en automático, esperamos." | systemd-cat -t Script_Vent_R710
	else
		printf "Activando control automático!" | systemd-cat -t Script_Vent_R710 
		ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
		touch $Fich_auto
	fi
else
	if [ -f $Fich_auto ];
	then
		printf "Está en automático, pasamos a manual." | systemd-cat -t Script_Vent_R710
		ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x00
		rm $Fich_auto
	else
		printf "Temperatura ($A_Temp C)" | systemd-cat -t Script_Vent_R710
	fi
	# -------------------------------------------------------------------------------
	# Temperatura por debajo, hay que bajar la velocidad si se puede
	# -------------------------------------------------------------------------------
	if [[ $A_Temp < $A_Temp_Deseada ]];
	then
		#cogemos valor de ventiladores y calculamos hexadecimal para reducir la velocidad tantos pasos como la diferencia en grados.
		velocidad=$(velocidad_ventiladores)
#		echo "Velocidad medida: $velocidad"
		case $velocidad in
			E_numero)
				printf "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Salimos!" | systemd-cat -t Script_Vent_R710
				exit -1
			;;
			E_fallo)
				printf "Error: Hay un ventilador fallido. Pasamos a automático y salimos!" | systemd-cat -t Script_Vent_R710
				ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
				touch $Fich_auto
				exit -1
			;;
			*)
#				echo "Diferencia= $(($velocidad - $Vel_minima))"
				pasos=$(( $(($velocidad - $Vel_minima)) / $D_rpm))
#				echo "Pasos= $pasos"
				if [ $(($pasos - $D_pasos)) -le 0 ];
				then
					pasos=0
				else
					pasos=$(($pasos - $D_pasos))
				fi
				pasos_hex=`printf "0x%02x" $pasos`
#				echo $pasos_hex
				ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x02 0xff $pasos_hex
			;;
		esac
	else
		# -------------------------------------------------------------------------------
		# Temperatura por encima, hay que subir la velocidad
		# -------------------------------------------------------------------------------
		if [[ $A_Temp > $A_Temp_Cambio ]];
		then
			#cogemos valor de ventiladores y calculamos hexadecimal para aumentar la velocidad tantos pasos como la diferencia en grados.
			velocidad=$(velocidad_ventiladores)
#			echo "Velocidad medida: $velocidad"
			case $velocidad in
				E_numero)
					printf "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Salimos!" | systemd-cat -t Script_Vent_R710
					exit -1
				;;
				E_fallo)
					printf "Error: Hay un ventilador fallido. Pasamos a automático y salimos!" | systemd-cat -t Script_Vent_R710
					ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
					touch $Fich_auto
					exit -1
				;;
				*)
#					echo "Diferencia= $(($velocidad - $Vel_minima))"
					pasos=$(( $(($velocidad - $Vel_minima)) / $D_rpm))
#					echo "Pasos= $pasos"
					if [ $(($pasos + $D_pasos)) -ge $(($Max_pasos)) ];
					then
						pasos=$Max_pasos
					else
						pasos=$(($pasos + $D_pasos))
					fi
					pasos_hex=`printf "0x%02x" $pasos`
#					echo $pasos_hex
					ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x02 0xff $pasos_hex
				;;
			esac
		else
			# -------------------------------------------------------------------------------
			# Temperatura dentro del margen, no se toca
			# -------------------------------------------------------------------------------
			printf "Trabajando a temperatura óptima" | systemd-cat -t Script_Vent_R710
			# -------------------------------------------------------------------------------
			# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
			# -------------------------------------------------------------------------------
			if [ -z "$PS1" ]; then
				echo "Temperatura ($A_Temp C)"
			fi
		fi
	fi
fi
