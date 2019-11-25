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

#  ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01 ## Auto
#  ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x00 ## Manual

# -------------------------------------------------------------------------------
# TODO:
#	- Controlar la interrupción para cerrar y limpiar adecuadamente.
#	- Pasar a /bin/sh o python y cambiar systemd-cat para ampliar compatibilidad.
#	- Configurar slacktee.sh y verificar la capacidad de notificación.
#	- Saltar la instrucción de nueva velocidad si ya está al mínimo
# -------------------------------------------------------------------------------

# -------------------------------------------------------------------------------
# A modificar para poner en marcha
# -------------------------------------------------------------------------------
# Configuración IPMI:
Host_IPMI=XXX.XXX.XXX.XXX	# Por defecto: 192.168.0.120
User_IPMI=root				# Por defecto: root
Passw_IPMI=calvin			# Por defecto: calvin
EncKey_IPMI=0000000000000000000000000000000000000000
# Configuración del script:
Fich_PID=/var/run/IPMI_VENT_R710.pid
Fich_auto=/root/auto_vent	# Fichero para saber si se ha puesto en auto
Fich_temp=/root/.temp		# Fichero para uso temporal
N_Vent=5					# Número de ventiladores del sistema
# -------------------------------------------------------------------------------
# A modificar para poner a punto
# -------------------------------------------------------------------------------
# Intervalo de s en el que se va a ejecutar el bucle
INTERVALO=30
# Temperaturas:
# 	Configura la temperatura ambiente máxima a la que dejará de tener el control
#		el script y pasará a control automático.
Max_A_Temp=40
#	Temperatura ambiente deseada de operación siempre ha de ser algo más elevada
#		que la temperatura ambiente de la sala, si no, el script nunca bajará la
#		velocidad de los ventiladores.
A_Temp_Deseada=25
#	Grados de margen antes de cambiar la velocidad de los ventiladores
#		(Histéresis)
Hist=5
# Velocidad de cambio:
#	Cantidad de pasos a modificar la velocidad cada vez que se den las
#		condiciones para el cambio
D_pasos=3
# Tope inferior
MIN_hex=0			# En el caso de R710 II 0x00 en decimal
Vel_minima=1080		# Velocidad media registrada para 0x00
# Tope superior
MAX_hex=100			# En el caso de R710 II 0x64 en decimal
#	Velocidad máxima para la que se quiere usar el script o el valor de MAX_hex
Vel_maxima=12480	# Velocidad registrada para 0x64
# Velocidad inicial deseada
Vel_ini_rpm=$Vel_minima	#puede ser cualquiera entre max y minima en RPM
# -------------------------------------------------------------------------------
# Calculados, no tocar
# -------------------------------------------------------------------------------
#	Valor máximo de pasos en los que se puede regular
MAX_pasos=$(($MAX_hex-$MIN_hex))
#	Delta de RPM calculado según valor max rpm, min rpm y pasos posibles.
D_rpm=$(($(($Vel_maxima-$Vel_minima))/$MAX_pasos))
#	Velocidad inicial para pasar en hex en decimal
Vel_ini=$(( $(($Vel_ini_rpm - $Vel_minima)) / $D_rpm))
# -------------------------------------------------------------------------------

# Función leer valores de ventilador y devolver velocidad media
# Salidas posibles
#	- RPM
#	- E_numero (error en número de ventiladores o líneas).
#	- E_fallo (hay un ventilador fallando).
function velocidad_ventiladores {
	bien=0
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
			vent_ok[$i]=`echo $linea |cut -s -d '|' -f 3 |xargs`
			vent_rpm[$i]=`echo $linea |cut -s -d '|' -f 5 |cut -d ' ' -f 2 |xargs`
			((i++))
		done < $Fich_temp
		rpm_suma=0
		for i in "${vent_ok[@]}";
		do
			if [ "${vent_ok[$i]}" == "ok" ];
			then
				rpm_suma=$(($rpm_suma + ${vent_rpm[$i]}))
			else
				salida_funcion="E_fallo"
			fi
		done
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

# -------------------------------------------------------------------------------
# Comprobamos si ya está corriendo 
# -------------------------------------------------------------------------------
if [ -f $Fich_PID ];
then
	printf "Se ha encontrado un fichero de PID, vamos a comprobar si sigue arrancado." | systemd-cat -t Script_Vent_R710
	if [ -n "$(ps -p `cat $Fich_PID` -o pid=)" ]
	then
		printf "El proceso sigue arrancado, salimos." | systemd-cat -t Script_Vent_R710
		# -------------------------------------------------------------------------------
		# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
		# -------------------------------------------------------------------------------
		if [ -z "$PS1" ]; then
			echo "Ya hay un proceso arrancado con el PID: "`cat $Fich_PID`
		fi
		exit -1
	else
		printf "El proceso no sigue arrancado, borramos el fichero y generamos uno propio." | systemd-cat -t Script_Vent_R710
		rm $Fich_PID
		echo $$ >> $Fich_PID
	fi
else
	printf "No se ha encontrado un fichero de PID, se continúa la ejecución." | systemd-cat -t Script_Vent_R710
	echo $$ >> $Fich_PID
fi

# -------------------------------------------------------------------------------
# Inicialización a control manual de los ventiladores 
# -------------------------------------------------------------------------------
if [ -f $Fich_auto ];
then
	printf "Se ha encontrado un fichero de señalización de cambio a automático, se borra." | systemd-cat -t Script_Vent_R710
	rm $Fich_auto
else
	printf "No se ha encontrado un fichero de señalización de cambio a automático, se continúa la ejecución." | systemd-cat -t Script_Vent_R710
fi

ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x00

# -------------------------------------------------------------------------------
# Reducimos a la velocidad inicial deseada 
# -------------------------------------------------------------------------------

ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x02 0xff `printf "0x%02x" $Vel_ini`

# -------------------------------------------------------------------------------
# Comienzo del bucle 
# -------------------------------------------------------------------------------

while [ 1 ]
do
	# Adquirimos el dato de la temperatura ambiente actual.
	A_Temp=$(ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI sdr type temperature |grep Ambient |grep degrees |grep -Po '\d{2}' | tail -1)

	# Calculamos la temperatura a la que aumentaríamos la velocidad de los ventiladores.
	A_Temp_Cambio=$(($A_Temp_Deseada + $Hist))

	if [[ $A_Temp > $Max_A_Temp ]];
	then
		printf "Warning: Máximo sobrepasado! Activando control automático! ($A_Temp C)" | systemd-cat -t Script_Vent_R710
		# TODO - Configurar slacktee.sh y verificar la capacidad de notificación.
		# echo "Warning: Máximo sobrepasado! Activando control automático! ($A_Temp C)" | /usr/bin/slacktee.sh -t "Script_Vent_R710 [$(hostname)]"
		# TODO - Controlar la interrupción para cerrar y limpiar adecuadamente.
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
			case $velocidad in
				E_numero)
					printf "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Salimos!" | systemd-cat -t Script_Vent_R710
					# -------------------------------------------------------------------------------
					# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
					# -------------------------------------------------------------------------------
					if [ -z "$PS1" ]; then
						echo "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Pasamos a automático y salimos!"
					fi
					ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
					touch $Fich_auto
					exit -1
				;;
				E_fallo)
					printf "Error: Hay un ventilador fallido. Pasamos a automático y salimos!" | systemd-cat -t Script_Vent_R710
					# -------------------------------------------------------------------------------
					# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
					# -------------------------------------------------------------------------------
					if [ -z "$PS1" ]; then
						echo "Error: Hay un ventilador fallido. Pasamos a automático y salimos!"
					fi
					ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
					touch $Fich_auto
					exit -1
				;;
				*)
#					TODO - Saltar la instrucción de nueva velocidad si ya está al mínimo
					pasos=$(( $(($velocidad - $Vel_minima)) / $D_rpm))
					if [ $(($pasos - $D_pasos)) -le 0 ];
					then
						pasos=0
					else
						pasos=$(($pasos - $D_pasos))
					fi
					pasos_hex=`printf "0x%02x" $pasos`
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
				case $velocidad in
					E_numero)
						printf "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Pasamos a automático y salimos!" | systemd-cat -t Script_Vent_R710
						# -------------------------------------------------------------------------------
						# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
						# -------------------------------------------------------------------------------
						if [ -z "$PS1" ]; then
							echo "Error: Se han leído un número distinto de líneas de ventilador de las esperadas. Pasamos a automático y salimos!"
						fi
						ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
						touch $Fich_auto
						exit -1
						;;
					E_fallo)
						printf "Error: Hay un ventilador fallido. Pasamos a automático y salimos!" | systemd-cat -t Script_Vent_R710
						# -------------------------------------------------------------------------------
						# Si se lanza desde una shell interactiva, escribimos, en otro caso, no.
						# -------------------------------------------------------------------------------
						if [ -z "$PS1" ]; then
							echo "Error: Hay un ventilador fallido. Pasamos a automático y salimos!"
						fi
						ipmitool -I lanplus -H $Host_IPMI -U $User_IPMI -P $Passw_IPMI -y $EncKey_IPMI raw 0x30 0x30 0x01 0x01
						touch $Fich_auto
						exit -1
					;;
					*)
						pasos=$(( $(($velocidad - $Vel_minima)) / $D_rpm))
						if [ $(($pasos + $D_pasos)) -ge $(($Max_pasos)) ];
						then
							pasos=$Max_pasos
						else
							pasos=$(($pasos + $D_pasos))
						fi
						pasos_hex=`printf "0x%02x" $pasos`
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
	sleep $INTERVALO
done
